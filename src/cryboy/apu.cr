require "./audio/abstract_channels" # so that channels don't need to all import
require "./audio/*"

lib LibSDL
  fun queue_audio = SDL_QueueAudio(dev : AudioDeviceID, data : Void*, len : UInt32) : Int
  fun get_queued_audio_size = SDL_GetQueuedAudioSize(dev : AudioDeviceID) : UInt32
  fun delay = SDL_Delay(ms : UInt32) : Nil
end

class APU
  BUFFER_SIZE =  1024
  SAMPLE_RATE = 65536 # Hz
  CHANNELS    =     2 # Left / Right

  FRAME_SEQUENCER_RATE = 512 # Hz

  @channel1 = Channel1.new
  @channel2 = Channel2.new
  @channel3 = Channel3.new
  @channel4 = Channel4.new
  @sound_enabled : Bool = false

  @buffer = Slice(Float32).new BUFFER_SIZE
  @buffer_pos = 0
  @cycles = 0_u32
  @frame_sequencer_stage = 0

  @left_enable = false
  @left_volume = 0_u8
  @right_enable = false
  @right_volume = 0_u8

  @nr51 : UInt8 = 0x00

  def initialize
    @audiospec = LibSDL::AudioSpec.new
    @audiospec.freq = SAMPLE_RATE
    @audiospec.format = LibSDL::AUDIO_F32SYS
    @audiospec.channels = CHANNELS
    @audiospec.samples = BUFFER_SIZE
    @audiospec.callback = nil
    @audiospec.userdata = nil

    @obtained_spec = LibSDL::AudioSpec.new
    raise "Failed to open audio" if LibSDL.open_audio(pointerof(@audiospec), pointerof(@obtained_spec)) > 0
    LibSDL.pause_audio 0
  end

  # tick apu forward by specified number of cycles
  def tick(cycles : Int) : Nil
    (0...cycles).each do
      @cycles &+= 1
      @channel1.step
      @channel2.step
      @channel3.step
      @channel4.step

      # tick frame sequencer
      if @cycles % (CPU::CLOCK_SPEED // FRAME_SEQUENCER_RATE) == 0
        @cycles = 0 # this is also an even divisor of the sample rate
        case @frame_sequencer_stage
        when 0
          @channel1.length_step
          @channel2.length_step
          @channel3.length_step
          @channel4.length_step
        when 1 then nil
        when 2
          @channel1.length_step
          @channel2.length_step
          @channel3.length_step
          @channel4.length_step
          @channel1.sweep_step
        when 3 then nil
        when 4
          @channel1.length_step
          @channel2.length_step
          @channel3.length_step
          @channel4.length_step
        when 5 then nil
        when 6
          @channel1.length_step
          @channel2.length_step
          @channel3.length_step
          @channel4.length_step
          @channel1.sweep_step
        when 7
          @channel1.volume_step
          @channel2.volume_step
          @channel4.volume_step
        else nil
        end
        @frame_sequencer_stage = 0 if (@frame_sequencer_stage += 1) > 7
      end

      # put 1 frame in buffer
      if @cycles % (CPU::CLOCK_SPEED // SAMPLE_RATE) == 0
        channel1_amp = @channel1.get_amplitude
        channel2_amp = @channel2.get_amplitude
        channel3_amp = @channel3.get_amplitude
        channel4_amp = @channel4.get_amplitude
        @buffer[@buffer_pos] = (((@nr51 & 0x80 > 0 ? channel4_amp : 0) +
                                 (@nr51 & 0x40 > 0 ? channel3_amp : 0) +
                                 (@nr51 & 0x20 > 0 ? channel2_amp : 0) +
                                 (@nr51 & 0x10 > 0 ? channel1_amp : 0)) / 4).to_f32
        @buffer[@buffer_pos + 1] = (((@nr51 & 0x08 > 0 ? channel4_amp : 0) +
                                     (@nr51 & 0x04 > 0 ? channel3_amp : 0) +
                                     (@nr51 & 0x02 > 0 ? channel2_amp : 0) +
                                     (@nr51 & 0x01 > 0 ? channel1_amp : 0)) / 4).to_f32
        @buffer_pos += 2
      end

      # push to SDL if buffer is full
      if @buffer_pos >= BUFFER_SIZE
        while LibSDL.get_queued_audio_size(1) > BUFFER_SIZE * sizeof(Float32) * 2
          LibSDL.delay(1)
        end
        LibSDL.queue_audio 1, @buffer, BUFFER_SIZE * sizeof(Float32)
        @buffer_pos = 0
      end
    end
  end

  # read from apu memory
  def [](index : Int) : UInt8
    case index
    when @channel1 then @channel1[index]
    when @channel2 then @channel2[index]
    when @channel3 then @channel3[index]
    when @channel4 then @channel4[index]
    when 0xFF24
      ((@left_enable ? 0b10000000 : 0) | (@left_volume << 4) |
        (@right_enable ? 0b00001000 : 0) | @right_volume).to_u8
    when 0xFF25 then @nr51
    when 0xFF26
      puts "READING NR52 - sound enabled? #{@sound_enabled} - channel 1 enabled? #{@channel1.enabled}"
      0x70_u8 |
        (@sound_enabled ? 0x80 : 0) |
        (@channel4.enabled ? 0b1000 : 0) |
        (@channel3.enabled ? 0b0100 : 0) |
        (@channel2.enabled ? 0b0010 : 0) |
        (@channel1.enabled ? 0b0001 : 0)
    else 0xFF_u8
    end
  end

  # write to apu memory
  def []=(index : Int, value : UInt8) : Nil
    return unless @sound_enabled || index == 0xFF26 || Channel3::WAVE_RAM_RANGE.includes?(index)
    case index
    when @channel1 then @channel1[index] = value
    when @channel2 then @channel2[index] = value
    when @channel3 then @channel3[index] = value
    when @channel4 then @channel4[index] = value
    when 0xFF24
      @left_enable = value & 0b10000000 > 0
      @left_volume = (value & 0b01110000) >> 4
      @right_enable = value & 0b00001000 > 0
      @right_volume = value & 0b00000111
    when 0xFF25 then @nr51 = value
    when 0xFF26
      if value & 0x80 == 0 && @sound_enabled
        (0xFF10..0xFF25).each { |addr| self[addr] = 0x00 }
        @sound_enabled = false
      else
        @sound_enabled = true
        @frame_sequencer_stage = 0
      end
    end
  end
end
