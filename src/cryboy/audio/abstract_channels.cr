# All of the channels were developed using the following guide on gbdev
# https://gbdev.gg8.se/wiki/articles/Gameboy_sound_hardware

abstract class SoundChannel
  property enabled : Bool = false
  @dac_enabled : Bool = false

  # NRx1
  property length_counter = 0
  @cycles_since_length_step : UInt16 = 0x0000

  # NRx4
  @length_enable : Bool = false
  @frequency_timer : UInt32 = 0x00000000

  # Step the channel, calling helpers to reload the period and step the wave generation
  def step : Nil
    if @frequency_timer == 0
      reload_frequency_timer
      step_wave_generation
    end
    @frequency_timer -= 1
    # Update frame sequencer counters
    @cycles_since_length_step += 1
  end

  # Step the length, disabling the channel if the length counter expires
  def length_step : Nil
    if @length_enable && @length_counter > 0
      @length_counter -= 1
      @enabled = false if @length_counter == 0
    end
    @cycles_since_length_step = 0
  end

  # Used so that channels can be matched with case..when statements
  abstract def ===(value) : Bool

  # Called when @frequency_timer reaches 0 and on trigger
  abstract def reload_frequency_timer : Nil

  # Called when @period reaches 0
  abstract def step_wave_generation : Nil

  abstract def get_amplitude : Float32

  abstract def [](index : Int) : UInt8
  abstract def []=(index : Int, value : UInt8) : Nil
end

abstract class VolumeEnvelopeChannel < SoundChannel
  # NRx2
  @starting_volume : UInt8 = 0x00
  @envelope_add_mode : Bool = false
  @period : UInt8 = 0x00

  @volume_envelope_timer : UInt8 = 0x00
  @current_volume : UInt8 = 0x00

  def volume_step : Nil
    if @period != 0
      @volume_envelope_timer -= 1 if @volume_envelope_timer > 0
      if @volume_envelope_timer == 0
        @volume_envelope_timer = @period
        if (@current_volume < 0xF && @envelope_add_mode) || (@current_volume > 0 && !@envelope_add_mode)
          @current_volume += (@envelope_add_mode ? 1 : -1)
        end
      end
    end
  end

  def init_volume_envelope : Nil
    @volume_envelope_timer = @period
    @current_volume = @starting_volume
  end

  def read_NRx2 : UInt8
    @starting_volume << 4 | (@envelope_add_mode ? 0x08 : 0) | @period
  end

  def write_NRx2(value : UInt8) : Nil
    @starting_volume = value >> 4
    @envelope_add_mode = value & 0x08 > 0
    @period = value & 0x07
    # Internal values
    @dac_enabled = value & 0xF8 > 0
    @enabled = false if !@dac_enabled
  end
end
