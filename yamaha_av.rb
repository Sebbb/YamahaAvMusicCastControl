require "net/http"
require "json"
require "socket"
require "event-loop"
require "event-loop/timer"

class YamahaAv
  def initialize(ip, device_id, debug: false)
    @debug=debug
    @new_status_handlers={
      "main" => Hash.new { |h,k| h[k] = [] },
      "func" => Hash.new { |h,k| h[k] = [] }
    }
    @device_id=device_id

    # for tcp
    @sockaddr = Socket.sockaddr_in(80, ip)
    @write_buf=nil
    @requests=[]
    @socket=nil
    @sent_bytes=0
    @block=nil # code block to be executed after data has been received
    @state=0 # statemachine for tcp
    # 0: initial
    # 1: handshake complete, prepare request - here it hangs when no request needs to be made but the connection is established
    # 2: send request
    # 3: request sent, wait for answer complete

    func_status_req = Net::HTTP::Get.new("/YamahaExtendedControl/v1/system/getFuncStatus")
    main_status_req = Net::HTTP::Get.new("/YamahaExtendedControl/v1/main/getStatus")
 
    @status={
      "main" => {},
      "func" => {}
    }

    # for udp
    @udpsock=UDPSocket.new
    @udpsock.extend(EventLoop::Watchable)
    @udpsock.bind("0.0.0.0",0)
    @udpsock.will_block=false
    @udpsock.monitor_events(:readable)
    @udpsock.on_readable{|x|
      begin
        data=JSON.parse(@udpsock.read_nonblock(1024))
      rescue
        break
      end
      break unless data["device_id"]==@device_id
      if data.has_key?('system') && data["system"].has_key?("func_status_updated")
        add_request(func_status_req) {|data2|
          status_update("func", JSON.parse(data2))
        }
      elsif data.has_key?('main')
        status_update("main", data["main"])
      else
        pp :push_status_update, data if @debug
      end
    }
    timer=EventLoop.every(590.seconds) {
      add_request(main_status_req){|data|
        status_update("main", JSON.parse(data))
      }
    }
    timer.sound_alarm # trigger directly

    add_request(func_status_req) {|data2|
      status_update("func", JSON.parse(data2))
    }
  end

  # section: main or func
  def on_new_status(section, setting, &block)
    @new_status_handlers[section][setting] << block
  end

  def new_status(section, setting, status)
    puts "Yamaha new status: Setting #{setting}: #{status.inspect}"
    @new_status_handlers[section][setting].each { |x|
      x.call(status)
    }
  end

  attr_accessor :requests

  def status_update(section, data)
    data.each{|k,v|
      if @status[section][k]!=v
        @status[section][k]=v
        if @new_status_handlers[section].has_key?(k)
          new_status(section, k, v)
        end
      end
    }
  end

  def prepare_req
    pp [:debug, :prepare_req, @requests] if @debug
    return false unless data=@requests.delete_at(0)
    req, @block=data
    req['connection'] = 'Keep-Alive'
    req["X-AppName"] = "MusicCast/4.00 (Seb)"
    req["X-AppPort"] = @udpsock.local_address.ip_port.to_s

    @write_buf = "#{req.method} #{req.path} HTTP/1.1\n" + req.each_header{}.map{|x| x.join(": ")}.join("\r\n") + "\r\n\r\n"
    pp [:debug, :prepare_req, true] if @debug
    return true
  end

  def add_request(req, &block)
    pp [:debug, :add_request, @socket] if @debug
    @requests << [req, block]
    if !@socket
      try_connect
    elsif @state==1
      @socket.monitor_events(:writable)
    end
  end

  def try_connect
    pp [:debug, :try_connect] if @debug

    return unless @write_buf || @requests.any?

    @socket = Socket.new(Socket::Constants::AF_INET, Socket::Constants::SOCK_STREAM, 0)
    @state=0
    @socket.extend(EventLoop::Watchable)
    @socket.will_block=false
    @socket.monitor_events(:readable, :writable)
    begin # emulate blocking connect
      @socket.connect_nonblock(@sockaddr)
    rescue IO::WaitWritable
    end

    @socket.on_writable {
      pp [:debug, :writable, @socket, @state] if @debug
      case @state
      when 0
        begin
          @socket.connect_nonblock(@sockaddr)  # will raise in case of an error
          @sent_bytes=0
          @state=1
          @read_buf=''
        rescue => e
          STDERR.puts "error: #{e.inspect}"
          disconnect
          EventLoop.after(5.seconds) {
            try_connect
          }
        end
      when 1
        if @write_buf
          @state=2 # still a request to be sent, the previous connection was broken....
        elsif prepare_req
          pp [:debug, :writable, :new_data] if @debug
          @read_buf=''
          @state=2
        else # no next request...
          pp [:debug, :writable, :no_new_data] if @debug
          @socket.ignore_event(:writable)
        end
      when 2
        @sent_bytes += @socket.write_nonblock(@write_buf[@sent_bytes..-1])
        
        if @write_buf.length==@sent_bytes # send complete
          pp [:debug, :writable, :write_complete] if @debug
          @socket.ignore_event(:writable)
          @state = 3
        end
      end
    }

    @socket.on_readable {
      pp [:debug, :readable, @state] if @debug
      case @state
      when 0 # error during connect
       # begin
       #   @socket.connect_nonblock(@sockaddr)
       # rescue => e
       #   STDERR.puts "error: #{e.inspect}"
       #   disconnect
       #   EventLoop.after(5.seconds) {
       #     try_connect
       #   }
       # end
      when 2
        raise "something is wrong: #{@state}"
      when 1 # disconnect during waiting for nothing
        pp [:debug, :readable, :disconnected] if @debug
        @socket.close
        @socket=nil
        #try_connect
      when 3
        # read data until end of length
        tmp=@socket.recv(1024)
        if tmp!=""
          @read_buf += tmp
          #pp [:debug, :readable, @read_buf] if @debug
          if header_length = @read_buf.index("\r\n\r\n")
            if @read_buf.match(/^Content-Length: (.*)$/)
              content_length = $1.to_i
              if @read_buf.length==content_length + header_length + 4
                #puts "receive done"
                if @read_buf.start_with?("HTTP/1.1 200 OK\r\n")
                  @block.call(@read_buf[header_length+4..-1]) if @block
                  @write_buf=nil
                  @sent_bytes=0
                  @state=1
                  @socket.monitor_event :writable
                else
                  STDERR.puts "Wrong answer: #{@read_buf}"
                  disconnect
                  EventLoop.after(5.seconds) {
                    try_connect
                  }
                end
              end
            else
              pp @read_buf
              raise "no content_length?!"
            end
          end
        end
      end
    }
  end
  def disconnect
    @socket.close
    @socket=nil
  end
end

if __FILE__ == $0

  yamaha = YamahaAv.new("192.168.1.207", "44FE3B60xxxx", debug: false)

  yamaha.on_new_status('main', "input") { |x|
    pp [:input, x]
  }

  yamaha.on_new_status('main', "volume") { |x|
    pp [:volume, x]
  }

  yamaha.on_new_status('func', "hdmi_out_1") { |x|
    pp [:hdmi, x]
  }

  #EventLoop.every(0.2) {printf "."}

  EventLoop.run

end
