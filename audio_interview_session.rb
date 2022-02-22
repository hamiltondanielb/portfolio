# frozen_string_literal: true

class AudioInterviewSession
  include Rails.application.routes.url_helpers
  attr_accessor :step_progression, :step

  delegate :audio_interview, to: :step_progression

  CONTINUE_KEYS = %w[1 2 3 4 5 7 6 8 9 0 #].freeze
  RESTART_KEYS = %w[*].freeze

  POST_PROMPT_BEEP = 'https://d111a4irec6an5.cloudfront.net/-1592344130753-beep.mp3'
  POST_RECORD_CHIME = 'https://d111a4irec6an5.cloudfront.net/audio_interview/application_sounds/beep.mp3'

  def initialize(step_progression)
    @step_progression = step_progression
    @step = step_progression.step
    @step_progression.build_audio_interview unless @step_progression.audio_interview
  end

  def create(phone_number, reconnecting = false)
    verify_url = verify_audio_interview_twilio_index_url(
      SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id, reconnect_call: reconnecting)
    )

    TwilioAdapter.pool.with do |client|
      client.calls.create(
        from: TwilioUtils.twilio_number(:voice, phone_number_country_code),
        to: phone_number,
        url: verify_url,
        status_callback: status_handler_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
        ),
        fallback_url: error_prompt,
        record: false
      )
    end
  end

  def verify(reconnecting)
    start_url = start_audio_interview_twilio_index_url(
      SubdomainHelper.generate_url_params(
        step_progression_id: @step_progression.id,
        reconnect_call: reconnecting,
        connection_type: 'phone'
      )
    )
    Twilio::TwiML::VoiceResponse.new do |response|
      response.gather(
        action: start_url,
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      ) do
        response.play(url: verify_prompt)
      end
    end
  end

  def start
    Twilio::TwiML::VoiceResponse.new do |response|
      # 1) Attempt first gather
      response.play(url: intro_prompt)

      response.redirect(
        gather_initial_response_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
        )
      )
    end
  end

  def gather_initial_response
    action_url = first_prompt_url
    Twilio::TwiML::VoiceResponse.new do |response|
      # 1) Attempt first gather
      response.gather(
        action: action_url,
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      )
      # 2) Gather again if first gather times out
      response.gather(
        action: action_url,
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      ) do
        response.play(url: no_activity_prompt)
      end
      # 3) Play goodbye prompt and let the call end if the second gather times out
      response.play(url: no_activity_end_call_prompt)
    end
  end

  def reconnect
    Twilio::TwiML::VoiceResponse.new do |response|
      response.play(url: reconnect_prompt)
      response.gather(
        action: play_prompt_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(
            step_progression_id: @step_progression.id,
            audio_prompt_id: audio_interview.current_audio_prompt.id
          )
        ),
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      )
    end
  end

  def advance
    ordered_prompts = @step.audio_prompts.order(:sequence, :created_at)
    current_prompt = audio_interview.current_audio_prompt

    if current_prompt.nil?
      if @step.audio_interview_play_practice_prompt?
        Analytics.track(
          name: 'audio_interview_practice_completed',
          person: @step_progression.attempt.user,
          object: @step_progression
        )

      end
      next_prompt = ordered_prompts.first
    elsif current_prompt.record_after_prompt && current_prompt.audio_recordings.find_by(step_progression_id: @step_progression.id).nil?
      next_prompt = current_prompt
    else
      next_prompt = ordered_prompts.find_by('sequence > ?', current_prompt.sequence)
    end

    # Redirect to play
    if next_prompt.present?
      audio_interview.update!(current_audio_prompt_id: next_prompt.id)

      twiml = self.redirect_to_play_prompt(next_prompt)
    else # No prompts left
      audio_interview.update!(completed_at: Time.zone.now)

      Lifecycle::StepProgression::CompleteService.execute(@step_progression, {})

      Analytics.track(
        name: 'audio_interview_completed',
        person: @step_progression.attempt.user,
        object: @step_progression
      )

      twiml = Twilio::TwiML::VoiceResponse.new do |response|
        response.redirect(outro_audio_interview_twilio_index_url(SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)))
      end
    end

    twiml
  end

  def redirect_to_play_prompt(audio_prompt)
    Twilio::TwiML::VoiceResponse.new do |response|
      response.redirect(
        play_prompt_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(
            step_progression_id: @step_progression.id,
            audio_prompt_id: audio_prompt.id
          )
        )
      )
    end
  end

  def play_prompt(audio_prompt)
    Twilio::TwiML::VoiceResponse.new do |response|
      audio_url = audio_prompt.url || audio_prompt.text_to_speech_audio_url

      if audio_url.present?
        Analytics.track(
          name: 'audio_interview_prompt_played',
          person: @step_progression.attempt.user,
          object: @step_progression
        )

        response.play(url: audio_url)
      else
        # For debugging
        response.say(message: audio_prompt.name || 'No audio prompt provided.', voice: 'woman')
      end

      if audio_prompt.record_after_prompt?
        if FeatureFlag.enabled?(Features::AUDIO_INTERVIEW_SELF_RECORD_0119, user_organization)
          response.redirect(
            continue_to_record_audio_interview_twilio_index_url(
              SubdomainHelper.generate_url_params(
                step_progression_id: @step_progression.id,
                audio_prompt_id: audio_interview.current_audio_prompt_id
              )
            )
          )
        else
          response.redirect(
            record_audio_interview_twilio_index_url(
              SubdomainHelper.generate_url_params(
                step_progression_id: @step_progression.id,
                audio_prompt_id: audio_interview.current_audio_prompt_id
              )
            )
          )
        end
      else
        response.redirect(advance_audio_interview_twilio_index_url(SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)))
      end
    end
  end

  def continue_to_record
    Twilio::TwiML::VoiceResponse.new do |response|
      prompt_to_record(response)
      response.gather(
        action: continue_to_record_handler_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(
            step_progression_id: @step_progression.id,
            audio_prompt_id: audio_interview.current_audio_prompt_id
          )
        ),
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      )

      prompt_to_record(response)
      response.gather(
        action: continue_to_record_handler_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(
            step_progression_id: @step_progression.id,
            audio_prompt_id: audio_interview.current_audio_prompt_id
          )
        ),
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      )

      response.play(url: no_activity_end_call_prompt)
    end
  end

  def record(audio_prompt)
    Twilio::TwiML::VoiceResponse.new do |response|
      response.play(url: POST_PROMPT_BEEP)
      response.record(
        action: recording_handler_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(
            step_progression_id: @step_progression.id,
            audio_prompt_id: audio_prompt.id
          )
        ),
        timeout: 10,
        trim: 'do-not-trim',
        # TODO: Discuss whether we should reimplement customizeable time limit and add it to the AudioPrompt model
        max_length: 600,
        transcribe: false,
        play_beep: false
      )
    end
  end

  def recording_finished
    Analytics.track(
      name: 'audio_interview_answer_recorded',
      person: @step_progression.attempt.user,
      object: @step_progression
    )

    Twilio::TwiML::VoiceResponse.new do |response|
      response.play(url: POST_RECORD_CHIME)
      response.redirect(advance_audio_interview_twilio_index_url(SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)))
    end
  end

  def end_call
    Twilio::TwiML::VoiceResponse.new(&:hangup)
  end

  def outro
    Twilio::TwiML::VoiceResponse.new do |response|
      if @step.audio_interview_skip_outro?
        response.hangup
      else
        response.play(url: outro_prompt)
      end
    end
  end

  def practice_prompt
    if FeatureFlag.enabled?(Features::AUDIO_INTERVIEW_SELF_RECORD_0119, user_organization)
      Twilio::TwiML::VoiceResponse.new do |response|
        response.play(url: practice_intro_prompt)

        response.redirect(
          continue_to_practice_record_audio_interview_twilio_index_url(
            SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
          )
        )
      end
    else
      Twilio::TwiML::VoiceResponse.new do |response|
        response.play(url: practice_intro_prompt)

        response.redirect(
          practice_record_audio_interview_twilio_index_url(
            SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
          )
        )
      end
    end
  end

  def continue_to_practice_record
    Twilio::TwiML::VoiceResponse.new do |response|
      prompt_to_record(response)
      response.gather(
        action: practice_record_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
        ),
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      )

      prompt_to_record(response)
      response.gather(
        action: practice_record_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
        ),
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      )

      response.play(url: no_activity_end_call_prompt)
    end
  end

  def practice_wait
    Twilio::TwiML::VoiceResponse.new do |response|
      response.pause(length: 2)
      response.redirect(practice_playback_audio_interview_twilio_index_url(SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)))
    end
  end

  def practice_record
    Twilio::TwiML::VoiceResponse.new do |response|
      response.play(url: POST_PROMPT_BEEP)
      response.record(
        action: practice_record_handler_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
        ),
        timeout: 30,
        trim: 'do-not-trim',
        max_length: 30,
        transcribe: false,
        play_beep: false
      )
    end
  end

  def practice_redirect
    Twilio::TwiML::VoiceResponse.new do |response|
      response.redirect(practice_playback_audio_interview_twilio_index_url(SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)))
    end
  end

  def practice_playback
    recording_url = audio_interview.practice_recording_url
    action_url = advance_audio_interview_twilio_index_url(SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id))

    Twilio::TwiML::VoiceResponse.new do |response|
      response.play(url: recording_url)

      response.gather(
        action: action_url,
        timeout: 5,
        num_digits: 1,
        finish_on_key: ''
      ) do
        response.play(url: practice_outro_prompt)
      end

      response.gather(
        action: action_url,
        timeout: 5,
        num_digits: 1,
        finish_on_key: ''
      ) do
        response.play(url: practice_outro_prompt)
      end

      response.play(url: no_activity_end_call_prompt)
    end
  end

  def idle
    Twilio::TwiML::VoiceResponse.new do |response|
      response.play(url: no_activity_prompt)
      response.gather(
        action: advance_audio_interview_twilio_index_url(SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)),
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      )

      response.play(url: no_activity_prompt)
      response.gather(
        action: advance_audio_interview_twilio_index_url(SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)),
        timeout: 10,
        num_digits: 1,
        finish_on_key: ''
      )

      response.play(url: no_activity_end_call_prompt)
    end
  end

  # Helpers
  def can_restart_prompt?(prompt)
    if @step.audio_interview_redo_limit.nil? || @step.audio_interview_redo_limit.zero?
      true
    else
      @step_progression.audio_recordings.where(audio_prompt_id: prompt.id).count < @step.audio_interview_redo_limit
    end
  end

  def user_continued?(digits)
    CONTINUE_KEYS.include?(digits)
  end

  def user_restarted?(digits)
    RESTART_KEYS.include?(digits)
  end

  def first_prompt_url
    if @step.audio_interview_play_practice_prompt?
      practice_prompt_audio_interview_twilio_index_url(
        SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
      )
    else
      advance_audio_interview_twilio_index_url(
        SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
      )
    end
  end

  def first_prompt_has_played?
    audio_interview.current_audio_prompt.present?
  end

  def translated_audio
    if international_prompts?
      I18n.t('audio_interview.audio_prompts', locale: locale)
    elsif FeatureFlag.enabled?(Features::DRADIS_AUDIO_FILE_FLAG, @step.assessment)
      AudioInterview::DRADIS_TEST_PROMPTS
    elsif FeatureFlag.enabled?(Features::AUDIO_INTERVIEW_SELF_RECORD_0119, user_organization)
      AudioInterview::SELF_RECORD_PROMPTS
    else
      {}
    end
  end

  def international_prompts?
    international_enabled? && I18n.exists?('audio_interview.audio_prompts', locale)
  end

  def intro_prompt
    if @step.audio_interview_custom_intro_prompt?
      @step.audio_interview_custom_intro_prompt
    else
      translated_audio[:intro] || AudioInterview::AUDIO_PROMPTS[:intro]
    end
  end

  def outro_prompt
    if @step.audio_interview_custom_outro_prompt?
      @step.audio_interview_custom_outro_prompt
    else
      translated_audio[:outro] || AudioInterview::AUDIO_PROMPTS[:outro]
    end
  end

  def start_record
    translated_audio[:start_record]
  end

  def emit_event(data)
    channel_name = PubSubAdapter.audio_channel_name(@step_progression.id)
    event_name = "call-status-#{@step_progression.id}"
    PubSubAdapter.emit_event(channel_name, event_name, data)

    Analytics.track(
      name: "audio_interview_emit_event_#{data[:action]}",
      person: @step_progression.attempt.user,
      object: @step_progression
    )
  end

  def practice_intro_prompt
    translated_audio[:practice_prompt] || AudioInterview::AUDIO_PROMPTS[:practice_prompt]
  end

  def practice_outro_prompt
    translated_audio[:practice_playback] || AudioInterview::AUDIO_PROMPTS[:practice_playback]
  end

  def verify_prompt
    translated_audio[:verify] || AudioInterview::AUDIO_PROMPTS[:verify]
  end

  def reconnect_prompt
    translated_audio[:reconnect] || AudioInterview::AUDIO_PROMPTS[:reconnect]
  end

  def no_activity_prompt
    translated_audio[:no_activity] || AudioInterview::AUDIO_PROMPTS[:no_activity]
  end

  def no_activity_end_call_prompt
    translated_audio[:no_activity_end_call] || AudioInterview::AUDIO_PROMPTS[:no_activity_end_call]
  end

  def error_prompt
    translated_audio[:error] || AudioInterview::AUDIO_PROMPTS[:error]
  end

  def user_organization
    return @user_organization if @user_organization

    organization_id = @step_progression.assessment.organization_id
    user_id = @step_progression.attempt.user_id
    @user_organization = UserOrganization.find_by(user_id: user_id, organization_id: organization_id)
  end

  def prompt_to_record(response)
    response.play(url: start_record)
  end

  def international_enabled?
    FeatureFlag.enabled?(Features::AUDIO_INTERVIEW_INTERNATIONAL, @step.assessment)
  end

  def country_code
    @country_code ||= @step&.assessment&.supported_countries&.first&.code
  end

  def locale
    @language_code ||= @step&.assessment&.language_code

    LanguageUtils.compatible_language("#{@language_code}-#{country_code}")
  end

  def phone_number_country_code
    return @step_progression.attempt.user.country_code unless international_enabled?

    country_code
  end
end
