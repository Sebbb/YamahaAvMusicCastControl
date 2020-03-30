# YamahaAvMusicCastControl
Ruby code to subscribe to MusicCast push events (volume control etc) in a non-blocking way

Uses event-loop. Example:

  yamaha.on_new_status('main', "input") { |x|
    pp [:input, x]
  }

  yamaha.on_new_status('main', "volume") { |x|
    pp [:volume, x]
  }

  yamaha.on_new_status('func', "hdmi_out_1") { |x|
    pp [:hdmi, x]
  }

->

# ruby yamaha_av.rb
Yamaha new status: Setting volume: 60
[:volume, 60]
Yamaha new status: Setting input: "tuner"
[:input, "tuner"]
Yamaha new status: Setting hdmi_out_1: true
[:hdmi, true]
Yamaha new status: Setting volume: 61
[:volume, 61]
Yamaha new status: Setting volume: 60
[:volume, 60]
Yamaha new status: Setting input: "alexa"
[:input, "alexa"]
Yamaha new status: Setting input: "tuner"
[:input, "tuner"]
Yamaha new status: Setting hdmi_out_1: false
[:hdmi, false]
Yamaha new status: Setting hdmi_out_1: true
[:hdmi, true]
