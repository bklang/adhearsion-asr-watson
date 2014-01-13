# encoding: utf-8
module AdhearsionASR::Watson
  module ControllerMethods

    #
    # Prompts for input, handling playback of prompts, DTMF grammar construction, and execution
    #
    # @example A basic DTMF digit collection:
    #   ask "Welcome, ", "/opt/sounds/menu-prompt.mp3",
    #       timeout: 10, terminator: '#', limit: 3
    #
    # The first arguments will be a list of sounds to play, as accepted by #play, including strings for TTS, Date and Time objects, and file paths.
    # :timeout, :terminator and :limit options may be specified to automatically construct a grammar, or grammars may be manually specified.
    #
    # @param [Object, Array<Object>] args A list of outputs to play, as accepted by #play
    # @param [Hash] options Options to modify the grammar
    # @option options [Boolean] :interruptible If the prompt should be interruptible or not. Defaults to true
    # @option options [Integer] :limit Digit limit (causes collection to cease after a specified number of digits have been collected)
    # @option options [Integer] :timeout Timeout in seconds before the first and between each input digit
    # @option options [String] :terminator Digit to terminate input
    # @option options [RubySpeech::GRXML::Grammar, Array<RubySpeech::GRXML::Grammar>] :grammar One of a collection of grammars to execute
    # @option options [String, Array<String>] :grammar_url One of a collection of URLs for grammars to execute
    # @option options [Hash] :input_options A hash of options passed directly to the Punchblock Input constructor. See
    # @option options [Hash] :output_options A hash of options passed directly to the Punchblock Output constructor
    #
    # @return [Result] a result object from which the details of the utterance may be established
    #
    # @see Output#play
    # @see http://rdoc.info/gems/punchblock/Punchblock/Component/Input.new Punchblock::Component::Input.new
    # @see http://rdoc.info/gems/punchblock/Punchblock/Component/Output.new Punchblock::Component::Output.new
    #
    def ask(*args)
      options = args.last.kind_of?(Hash) ? args.pop : {}
      options = default_options.merge(options)
      prompts = args.flatten

      options[:timeout] || options[:limit] || options[:terminator] || raise(ArgumentError, "You must specify at least one of limit, terminator or timeout")

      grammars = AdhearsionASR::AskGrammarBuilder.new(options).grammars

      output_document = prompts.empty? ? nil : output_formatter.ssml_for_collection(prompts)

      play output_document if output_document

      recording = record(start_beep: false, initial_timeout: 4.seconds, final_timeout: 1.seconds, format: 'wav', direction: :send).complete_event.recording
      # TODO: Make this work when Adhearsion isn't running on the same server as the telephony engine
      listener = Celluloid::Actor[:att_speech].future.speech_to_text File.read(recording.uri.sub('file://', ''))

      # Allow masking sounds while ASR is processing
      yield if block_given?

      # TODO: Map this into a Response object
      begin
        interpretation = listener.value(options[:timeout])
        logger.trace "Result from AT&T Watson: #{interpretation.inspect}"
        if interpretation.recognition.status == 'OK' && interpretation.recognition.n_best.confidence >= options[:min_confidence]
          interpretation.recognition.n_best.result_text
        end
      rescue Celluloid::TimeoutError
        # TODO return a no-match response
        return nil
      end
    end

  private
    def default_options
      {
        timeout: Plugin.config.timeout,
        min_confidence: Plugin.config.min_confidence,
        language: Plugin.config.input_language
      }
    end
  end
end
