# frozen_string_literal: true

class Integrations::AudioInterviewTwilioController < Integrations::BaseController
  include ::NewRelic::Agent::MethodTracer

  DISCONNECTED_CALL_STATUSES = %w[busy no-answer canceled].freeze
  FAILED_CALL_STATUS = 'failed'

  before_action :set_step_progression, :set_audio_interview_session, only: [
    :status_handler, :verify, :start, :advance, :play_prompt, :continue_to_record,
    :continue_to_record_handler, :record, :recording_handler, :practice_prompt,
    :continue_to_practice_record, :practice_playback, :practice_wait,
    :practice_record_handler, :idle, :outro, :practice_record,
    :gather_initial_response, :end_call
  ]

  # PHONE ONLY
  def verify
    twiml = @audio_interview_session.verify(params[:reconnect_call])
    @audio_interview_session.emit_event(action: 'verifying', call_sid: params[:CallSid])
    render xml: twiml.to_xml
  end
  add_method_tracer :verify, 'Custom/twilio/verify'

  # Handle status updates
  # If call ends, notify the client
  def status_handler
    @step_progression.build_audio_interview unless @step_progression&.audio_interview
    @step_progression.audio_interview.update!(
      final_status: params[:CallStatus],
      recording_url: params[:RecordingUrl],
      recording_sid: params[:RecordingSid],
      recording_duration: params[:RecordingDuration]
    )

    if params[:CallStatus] == 'completed' && @step_progression.completed?
      @audio_interview_session.emit_event(action: 'ended', call_sid: params[:CallSid])
    elsif %w[completed busy no-answer canceled failed].include?(params[:CallStatus])
      if @step_progression.audio_interview.skip_disconnect?
        ApplicationLogger.debug(
          :audio_interview_changed_number,
          data: log_parameters
        )
        @step_progression.audio_interview.update!(skip_disconnect: false)

        return render status: :ok, plain: ''
      end

      log_disconnection

      @audio_interview_session.emit_event(
        action: 'disconnected',
        call_sid: params[:CallSid],
        call_status: params[:CallStatus],
        sip_response_code: params[:SipResponseCode],
        phone_number: params[:To],
        data: { audio_interview_debug_disconnect_count: @step_progression.audio_interview.debug_disconnect_count }
      )
    end

    render status: :ok, plain: ''
  end

  def start
    ActiveRecord::Base.transaction do
      @step_progression.update_columns(twilio_call_sid: params[:CallSid])
      @audio_interview_session.emit_event(action: 'update_call_sid', call_sid: params[:CallSid])

      @step_progression.build_audio_interview unless @step_progression.audio_interview
      @step_progression.audio_interview.update_columns(
        debug_connection_type: params[:connection_type],
        debug_has_verified: true,
        started_at: @step_progression.audio_interview.started_at || Time.zone.now
      )
    end

    if params[:reconnect_call].present? && @audio_interview_session.first_prompt_has_played?
      Analytics.track(
        name: 'audio_interview_reconnected',
        person: @step_progression.attempt.user,
        object: @step_progression,
        data: log_parameters
      )

      twiml = @audio_interview_session.reconnect
      @audio_interview_session.emit_event(action: 'reconnected', call_sid: params[:CallSid])
    else
      if params[:connection_type] == 'phone'
        event_type_connection = 'audio_interview_phone_connected'
      else
        event_type_connection = 'audio_interview_computer_connected'
      end
      Analytics.track(
        name: event_type_connection,
        person: @step_progression.attempt.user,
        object: @step_progression,
        data: log_parameters
      )
      twiml = @audio_interview_session.start
      @audio_interview_session.emit_event(action: 'connected', call_sid: params[:CallSid])

      log_connected!
    end

    render xml: twiml.to_xml
  end
  add_method_tracer :start, 'Custom/twilio/start'

  def gather_pin
    render xml: AudioInterviewPin.new.gather_pin.to_xml
  end
  add_method_tracer :gather_pin, 'Custom/twilio/gather_pin'

  def verify_pin
    result = AudioInterview.valid_pin(params['Digits'].to_i).first
    return render xml: AudioInterviewPin.new.retry_pin.to_xml if result.nil?

    set_step_progression(result[:step_progression_id])
    set_audio_interview_session
    @audio_interview_session.emit_event(action: 'update_call_sid', call_sid: params[:CallSid])
    @audio_interview_session.emit_event(action: 'user_called_in')

    verify
  end
  add_method_tracer :verify_pin, 'Custom/twilio/verify_pin'

  def gather_initial_response
    twiml = @audio_interview_session.gather_initial_response
    @audio_interview_session.emit_event(action: 'awaiting_initial', call_sid: params[:CallSid])

    render xml: twiml.to_xml
  end
  add_method_tracer :gather_initial_response, 'Custom/twilio/gather_initial_response'

  def practice_record_handler
    @step_progression.build_audio_interview unless @step_progression.audio_interview
    @step_progression.audio_interview.update!(practice_recording_url: params[:RecordingUrl])

    twiml = @audio_interview_session.practice_redirect

    render xml: twiml.to_xml
  end
  add_method_tracer :practice_record_handler, 'Custom/twilio/practice_record_handler'

  def practice_record
    twiml = @audio_interview_session.practice_record

    @audio_interview_session.emit_event(action: 'practice_recording', call_sid: params[:CallSid])
    render xml: twiml.to_xml
  end
  add_method_tracer :practice_record, 'Custom/twilio/practice_record'

  # Needed for the in-browser continue button
  def practice_wait
    twiml = @audio_interview_session.practice_wait

    @audio_interview_session.emit_event(action: 'practice_wait', call_sid: params[:CallSid])

    render xml: twiml.to_xml
  end
  add_method_tracer :practice_wait, 'Custom/twilio/practice_wait'

  def advance
    render xml: @audio_interview_session.advance.to_xml
  end
  add_method_tracer :advance, 'Custom/twilio/advance'

  def practice_prompt
    Analytics.track(
      name: 'audio_interview_practice_started',
      person: @step_progression.attempt.user,
      object: @step_progression,
      data: log_parameters
    )

    @audio_interview_session.emit_event(action: 'practice_prompt', call_sid: params[:CallSid])
    render xml: @audio_interview_session.practice_prompt.to_xml
  end
  add_method_tracer :practice_prompt, 'Custom/twilio/practice_prompt'

  def continue_to_practice_record
    Analytics.track(
      name: 'audio_interview_continue_to_practice_record',
      person: @step_progression.attempt.user,
      object: @step_progression,
      data: log_parameters
    )

    @audio_interview_session.emit_event(action: 'continue_to_practice_record', call_sid: params[:CallSid])
    render xml: @audio_interview_session.continue_to_practice_record.to_xml
  end
  add_method_tracer :continue_to_practice_record, 'Custom/twilio/continue_to_practice_record'

  def end_call
    render xml: @audio_interview_session.end_call.to_xml
  end
  add_method_tracer :end_call, 'Custom/twilio/end_call'

  def practice_playback
    @audio_interview_session.emit_event(action: 'practice_playback', call_sid: params[:CallSid])
    ApplicationLogger.debug(
      :audio_interview_practice_completed,
      log_parameters
    )

    @step_progression.build_audio_interview unless @step_progression.audio_interview
    @step_progression.audio_interview.update!(debug_has_practiced: true)

    render xml: @audio_interview_session.practice_playback.to_xml
  end
  add_method_tracer :practice_playback, 'Custom/twilio/practice_playback'

  # Play audio prompt
  def play_prompt
    next_prompt = AudioPrompt.find(params[:audio_prompt_id])
    twiml = @audio_interview_session.play_prompt(next_prompt)

    # Soft destroy prev recording if replay
    previous_recording = @step_progression.audio_recordings.find_by(audio_prompt: next_prompt)
    previous_recording.destroy if previous_recording.present?

    Analytics.track(
      name: "prompt_#{next_prompt[:sequence].to_i}_played",
      person: @step_progression.attempt.user,
      object: @step_progression,
      data: log_parameters
    )

    @audio_interview_session.emit_event(action: 'playing', call_sid: params[:CallSid])
    render xml: twiml.to_xml
  end
  add_method_tracer :play_prompt, 'Custom/twilio/play_prompt'

  def continue_to_record
    Analytics.track(
      name: 'audio_interview_continue_to_record',
      person: @step_progression.attempt.user,
      object: @step_progression,
      data: log_parameters
    )

    @audio_interview_session.emit_event(action: 'continue_to_record', call_sid: params[:CallSid])
    render xml: @audio_interview_session.continue_to_record.to_xml
  end
  add_method_tracer :continue_to_record, 'Custom/twilio/continue_to_record'

  def continue_to_record_handler
    previous_audio_prompt = AudioPrompt.find(params[:audio_prompt_id])
    if @audio_interview_session.user_continued?(params[:Digits])
      emit_event(params[:CallSid], action: 'recording')
      twiml = @audio_interview_session.record(previous_audio_prompt)
    elsif @audio_interview_session.user_restarted?(params[:Digits])
      if @audio_interview_session.can_restart_prompt?(previous_audio_prompt)
        twiml = @audio_interview_session.redirect_to_play_prompt(previous_audio_prompt)
      else # Out of retries
        twiml = @audio_interview_session.recording_finished
      end
    else
      twiml = @audio_interview_session.idle
    end

    render xml: twiml.to_xml
  end

  # Record for prompt, notify client that recording has started
  def record
    audio_prompt = AudioPrompt.find(params[:audio_prompt_id])
    twiml = @audio_interview_session.record(audio_prompt)

    Analytics.track(
      name: "prompt_#{audio_prompt[:sequence].to_i}_answered",
      person: @step_progression.attempt.user,
      object: @step_progression,
      data: log_parameters
    )

    @audio_interview_session.emit_event(action: 'recording', call_sid: params[:CallSid])
    render xml: twiml.to_xml
  end
  add_method_tracer :record, 'Custom/twilio/record'

  def recording_handler
    previous_audio_prompt = AudioPrompt.find(params[:audio_prompt_id])

    if @audio_interview_session.user_continued?(params[:Digits])
      twiml = @audio_interview_session.recording_finished
    elsif @audio_interview_session.user_restarted?(params[:Digits])
      if @audio_interview_session.can_restart_prompt?(previous_audio_prompt)
        twiml = @audio_interview_session.redirect_to_play_prompt(previous_audio_prompt)
      else # Out of retries
        twiml = @audio_interview_session.recording_finished
      end
    else
      twiml = @audio_interview_session.idle
    end

    # This has to happen after the twiml is generated
    # so the audio_recordings.count is accurate
    @step_progression.audio_recordings.create!(
      audio_prompt: previous_audio_prompt,
      url: params[:RecordingUrl],
      twilio_recording_sid: params[:RecordingSid],
      duration: params[:RecordingDuration]
    )

    render xml: twiml.to_xml
  end
  add_method_tracer :recording_handler, 'Custom/twilio/recording_handler'

  def idle
    @audio_interview_session.emit_event(action: 'idle', call_sid: params[:CallSid])

    @step_progression.audio_interview.update(debug_idle: true)
    Analytics.track(
      name: 'audio_interview_idle',
      person: @step_progression.attempt.user,
      object: @step_progression,
      data: log_parameters
    )

    render xml: @audio_interview_session.idle.to_xml
  end
  add_method_tracer :idle, 'Custom/twilio/idle'

  def outro
    client_data = {
      action: 'completed',
      call_sid: params[:CallSid],
      prompt_playing: !@step_progression.step.audio_interview_skip_outro?,
      completed_at: @step_progression.completed_at
    }

    @audio_interview_session.emit_event(client_data)
    render xml: @audio_interview_session.outro.to_xml
  end
  add_method_tracer :outro, 'Custom/twilio/outro'

  def log_parameters
    {
      call_sid: params[:CallSid],
      call_status: params[:CallStatus],
      call_duration: params[:CallDuration],
      assessment_id: @step_progression&.step&.assessment_id
    }
  end

  private

  def set_step_progression(step_progression_id = nil) # rubocop:disable Naming/AccessorMethodName
    if step_progression_id
      @step_progression = StepProgression.find(step_progression_id)
    elsif params[:step_progression_id]
      @step_progression = StepProgression.find(params[:step_progression_id])
    elsif params[:call_sid].present?
      @step_progression = StepProgression.find_by(twilio_call_sid: params[:call_sid])
    elsif params[:CallSid].present?
      @step_progression = StepProgression.find_by(twilio_call_sid: params[:CallSid])
    end

    render status: :bad_request, plain: 'Request is missing valid call parameters' if @step_progression.blank?
  end

  def set_audio_interview_session
    @audio_interview_session = AudioInterviewSession.new(@step_progression)
  end

  def log_connected!
    Metrics.increment('system.twilio.connected')
  end

  def log_failed!
    Metrics.increment('system.twilio.failed')
  end

  def log_disconnection
    if DISCONNECTED_CALL_STATUSES.include?(params[:CallStatus])
      event_name = 'audio_interview_failed_to_connect'
      log_failed!
    elsif params[:CallStatus] == FAILED_CALL_STATUS
      event_name = 'audio_interview_failed'

      @step_progression.build_audio_interview unless @step_progression.audio_interview
      @step_progression.audio_interview.update!(debug_call_failed: true)

      log_failed!
    else
      event_name = 'audio_interview_disconnected'
      @step_progression.audio_interview.update(debug_disconnect_count: @step_progression.audio_interview.debug_disconnect_count + 1)
    end

    Analytics.track(
      name: event_name,
      person: @step_progression.attempt.user,
      object: @step_progression,
      data: log_parameters
    )
  end
end
