# encoding: utf-8
module AdhearsionASR::Watson
  class Plugin < Adhearsion::Plugin
    config :adhearsion_asr_watson do
      auto_include true, transform: Proc.new { |v| v == 'true' }, desc: "Enable or disable auto inclusion of overridden Adhearsion Core methods in all call controllers."
      min_confidence 0.5, desc: 'The default minimum confidence level used for all recognizer invocations.', transform: Proc.new { |v| v.to_f }
      timeout 5, desc: 'The default timeout (in seconds) used for all recognizer invocations.', transform: Proc.new { |v| v.to_i }
      input_language 'en-US', desc: 'The default language set on generated grammars. Set nil to use platform default.'
      api_key '', desc: 'AT&T API Key'
      api_secret '', desc: 'AT&T API Secret'
    end

    init after: :adhearsion_asr do
      if config[:auto_include]
        ::Adhearsion::CallController.mixin ::AdhearsionASR::Watson::ControllerMethods
      end

      ATTSpeech.supervise_as :att_speech, config[:api_key], config[:api_secret], 'SPEECH'
      #ATTSpeech.supervise_as :att_tts, config[:api_key], config[:api_secret], 'TTS'

    end
  end
end
