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
      orig_args = args.dup
      options = args.last.kind_of?(Hash) ? args.pop : {}
      options = default_options.merge(options)
      prompts = args.flatten.compact

      options[:timeout] || options[:limit] || options[:terminator] || raise(ArgumentError, "You must specify at least one of limit, terminator or timeout")

      grammars = AdhearsionASR::AskGrammarBuilder.new(options).grammars

      output_document = prompts.empty? ? nil : output_formatter.ssml_for_collection(prompts)
      if options[:mode] == :voice
        # AT&T Watson should only be used for voice grammars
        execute_prompt output_document, grammars, options
      else
        super *orig_args
      end
    end

    def execute_prompt(output_document, grammars, options)
      options = default_options.merge(options)
      play output_document if output_document

      # TODO: Support more than one grammar
      grammar = grammars.first[:value]

      recording = record(start_beep: false, initial_timeout: 4.seconds, final_timeout: 1.seconds, format: 'wav', direction: :send).complete_event.recording
      # TODO: Make this work when Adhearsion isn't running on the same server as the telephony engine
      listener = Celluloid::Actor[:att_speech].future.speech_to_text File.read(recording.uri.sub('file://', '')), 'audio/wav', 'Generic', grammar: grammar

      # Allow masking sounds while ASR is processing
      yield if block_given?

      begin
        interpretation = listener.value(options[:timeout])
        logger.trace "Result from AT&T Watson: #{interpretation.inspect}"
        if interpretation.error_message || interpretation.request_error
          logger.error "Watson API returned an error: #{interpretation.error_message || interpretation.request_error.service_exception.text}"
          create_nomatch
        elsif interpretation.recognition.status == 'OK' && interpretation.recognition.n_best.confidence >= options[:min_confidence]
          # FIXME: Should min_confidence be replaced with :grade? grade="accept"
          result = create_result interpretation.recognition
          result.status = :match
          result.confidence = interpretation.recognition.n_best.confidence
          result
        elsif interpretation.recognition.status == 'Speech Not Recognized'
          create_nomatch
        else
          create_nomatch
        end
      rescue NoMethodError
        # This is a catch-all in case one of the accessors into the AT&T response is a nil, causing a NoMethodError on that object.
        # Dirty, but at least we should log the reason this way.
        logger.error interpretation.inspect
        create_nomatch
      rescue Celluloid::TimeoutError
        create_nomatch
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

    def create_result(recognition)
      text = recognition.n_best.result_text
      confidence = recognition.n_best.confidence
      grammar_id = 'http://grammar' # FIXME
      nlsml = RubySpeech::NLSML.draw grammar: grammar_id do
        interpretation confidence: confidence do
          if recognition.n_best.has_key? 'nlu_hypothesis'
            input text, mode: :voice
            instance do
              recognition.n_best.nlu_hypothesis.out.keys.each do |key|
                send key, recognition.n_best.nlu_hypothesis.out[key].to_s
              end
            end
          end
        end
      end

      AdhearsionASR::Result.new.tap do |result|
        result.mode           = :voice
        result.status         = :match
        result.utterance      = text
        result.interpretation = text
        # Extra parse step below is required pending https://github.com/benlangfeld/ruby_speech/issues/22
        result.nlsml          = RubySpeech::NLSML::Document.new nlsml
      end
    end

    def create_nomatch
      AdhearsionASR::Result.new.tap do |result|
        result.mode   = :voice
        result.status = :nomatch
      end
    end
  end
end
