# frozen_string_literal: true

class Candidate::Api::AudioInterviewController < BaseStepProgressionController
  before_action :set_step_progression, :set_audio_interview_session

  def initial_data
    @step = @step_progression.step
    @step_progression.audio_interview.generate_pin
    init_twilio

    render json: {
      twilio_token: @twilio_token,
      custom_legal_disclaimer: @step.legal_disclaimer,
      step_progression: @step_progression,
      audio_interview: @step_progression.audio_interview,
      audio_interview_call_in_number: ENV.fetch('AUDIO_INTERVIEW_CALL_IN_NUMBER'),
      new_audio_prompts: use_new_audio_prompts?,
      country_codes: view_context.country_options_for_select,
      progress: Progress::AssignmentSerializer.new(current_user_organization, @step_progression).value,
      locale: international_locale,
      audio_interview_v2_assessment: audio_interview_v2_assessment?
    }
  end

  def audio_interview_v2_assessment?
    FeatureFlag.enabled?(Features::AUDIO_INTERVIEW_V2) && @audio_interview_session.international_enabled?
  end

  def use_new_audio_prompts?
    @audio_interview_session.international_enabled? || use_dradis_audio_prompts?
  end

  def use_dradis_audio_prompts?
    FeatureFlag.enabled?(Features::DRADIS_AUDIO_FILE_FLAG, @step.assessment)
  end

  def international_locale
    return nil unless @audio_interview_session.international_enabled?

    @audio_interview_session.locale
  end

  def connect
    return render status: :bad_request, json: {} if params[:phone].blank?
    return render json: { completed: @step_progression.completed? } if @step_progression.completed?

    phone_number = params[:phone]

    raise Exceptions::AttemptReset if @step_progression.attempt.nil?

    begin
      @call = @audio_interview_session.create(phone_number, params[:reconnect_call])
    rescue Twilio::REST::TwilioError => e
      error = AudioInterviews::Errors::ConnectionErrorHandler.new(e, @step_progression, params).twilio_error
      return render json: { error: error }
    else
      log_audio_event(
        'connected_phone',
        data: { twilio_call_sid: @call.sid }
      )
      @step_progression.update(twilio_call_sid: @call.sid, started_at: Time.zone.now)
      @audio_interview_session.emit_event(action: 'update_call_sid', call_sid: @call.sid)

      log_queued!
    end

    render json: @step_progression
  rescue AudioInterviews::Errors::AudioRecordingError => e
    error = AudioInterviews::Errors::ConnectionErrorHandler.new(e, @step_progression, params).connection_error
    render status: :bad_request, json: { error: error }
  rescue Exceptions::AttemptReset
    render status: :bad_request, json: {
      reason: 'attempt_reset',
      redirect_path: candidate_attempts_path
    }
  end

  def update_call
    return render json: { completed: @step_progression.completed? } if @step_progression.completed?

    begin
      @call = TwilioAdapter.make_call(params[:call_sid])
    rescue StandardError => e
      Raven.extra_context(
        step_progression_id: @step_progression&.id
      )
      Raven.capture_exception(e)
      return render status: :bad_request, json: { error: 'call sid not found' }
    end

    audio_interview = @step_progression.audio_interview
    redirect_call_url = nil

    case params[:call_action]
    when 'practice_recording'
      redirect_call_url = practice_record_audio_interview_twilio_index_url(
        SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
      )
    when 'recording'
      redirect_call_url = record_audio_interview_twilio_index_url(
        SubdomainHelper.generate_url_params(
          step_progression_id: @step_progression.id,
          audio_prompt_id: @step_progression.audio_interview.current_audio_prompt_id
        )
      )
    when 'start_call'
      redirect_call_url = @audio_interview_session.first_prompt_url
    when 'practice_playback'
      redirect_call_url = practice_wait_audio_interview_twilio_index_url(
        SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
      )
    when 'advance'
      redirect_call_url = advance_audio_interview_twilio_index_url(
        SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
      )
    when 'end_call'
      redirect_call_url = end_call_audio_interview_twilio_index_url(
        SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
      )
    when 'end_call_skip_disconnect'
      @step_progression.build_audio_interview unless audio_interview
      @step_progression.audio_interview.update!(skip_disconnect: true)

      redirect_call_url = end_call_audio_interview_twilio_index_url(
        SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
      )
    when 'replay_prompt'
      if @audio_interview_session.can_restart_prompt?(audio_interview.current_audio_prompt)
        redirect_call_url = play_prompt_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(
            step_progression_id: @step_progression.id,
            audio_prompt_id: audio_interview.current_audio_prompt_id
          )
        )
      else # Out of retries
        redirect_call_url = advance_audio_interview_twilio_index_url(
          SubdomainHelper.generate_url_params(step_progression_id: @step_progression.id)
        )
      end
    end

    log_audio_event(
      'update_call',
      redirect_call_url: redirect_call_url,
      action: params[:call_action], sid: params[:call_sid]
    )

    unless redirect_call_url.nil?
      @call.update(
        url: redirect_call_url,
        method: 'POST'
      )
    end

    render json: {}
  rescue Twilio::REST::RestError => e
    log_audio_event(
      'update_error',
      twilio_error_code: e.code,
      twilio_error_message: e.message
    )
    render status: :bad_request, json: { error: e.message }
  rescue Twilio::REST::TwilioError => e
    log_audio_event(
      'update_error',
      twilio_error_message: e.message
    )
    render status: :bad_request, json: { error: e.message }
  end

  def validate_phone
    return render json: { valid: false } if params[:phone_number].blank?

    phone_number = TwilioAdapter.phone_number_validation(params[:phone_number], params[:country_code])

    log_audio_event(
      'phone_validation_success',
      valid: true
    )

    # if invalid, throws an exception. If valid, no problems.
    render json: { valid: true, phone_number_formatted: phone_number.national_format }
  rescue Twilio::REST::TwilioError, Timeout::Error => e
    # log error, step_progression, phone
    log_audio_event(
      'phone_validation_failed',
      error: e.message,
      country_code: params[:country_code]
    )
    render json: { valid: false }
  end

  private

  def set_step_progression
    if params[:step_progression_id]
      @step_progression = StepProgression.find(params[:step_progression_id])
    elsif params[:call_sid].present?
      @step_progression = StepProgression.find_by(twilio_call_sid: params[:call_sid])
    elsif params[:CallSid].present?
      @step_progression = StepProgression.find_by(twilio_call_sid: params[:CallSid])
    elsif current_user_organization.present?
      @step_progression = first_incomplete_step_progression
    end

    render status: :bad_request, plain: 'Request is missing valid call parameters' if @step_progression.blank?
  end

  def set_audio_interview_session
    @audio_interview_session = AudioInterviewSession.new(@step_progression)
  end

  def init_twilio
    twilio_capability = Twilio::JWT::ClientCapability.new(Rails.configuration.x.TWILIO_ACCOUNT_SID, Rails.configuration.x.TWILIO_AUTH_TOKEN)

    app_sid = Rails.configuration.x.TWILIO_APP_SID

    outgoing_scope = Twilio::JWT::ClientCapability::OutgoingClientScope.new(app_sid)
    twilio_capability.add_scope(outgoing_scope)

    @twilio_token = twilio_capability.to_s
  rescue StandardError
    Raven.capture_exception('Twilio Capability Error')
  end

  def log_queued!
    Metrics.increment('system.twilio.queued')
  end

  def log_audio_event(name, data = {})
    Analytics.track(
      name: "audio_interview_#{name}",
      person: @step_progression.attempt.user,
      object: @step_progression,
      data: data
    )
  end
end
