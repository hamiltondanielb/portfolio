# frozen_string_literal: true

require 'rails_helper'

def convert_twiml(twiml)
  Hash.from_xml(twiml.to_xml)
end

RSpec.describe AudioInterviewSession do
  before do
    assessment1 = create(:assessment)

    @audio_interview_practice_recording_url = Faker::Internet.url
    @step1 = create(:step, name: Faker::Lorem.sentence, assessment: assessment1, sequence: 1)
    @audio_prompt = create(:audio_prompt, step: @step1, record_after_prompt: false)
    @step_progression = create(:step_progression, step: @step1)
    @audio_interview = create(:audio_interview, step_progression: @step_progression, current_audio_prompt: nil)
    @audio_interview.update!(practice_recording_url: @audio_interview_practice_recording_url)
    @step_progression.touch(:started_at)
    @audio_interview_session = AudioInterviewSession.new(@step_progression)
    @response = nil
    VCR.use_cassette 'twilio/connect' do
      @response = @audio_interview_session.create('15126451213')
    end
  end
  it 'handles the full Twilio interview flow' do
    expect(@response.class).to eq(Twilio::REST::Api::V2010::AccountContext::CallInstance)

    verify_response = @audio_interview_session.verify(false)
    expect(convert_twiml(verify_response)['Response']['Play']).to eq(AudioInterview::AUDIO_PROMPTS[:verify])

    start_response = @audio_interview_session.start
    expect(convert_twiml(start_response)['Response']['Play']).to eq(AudioInterview::AUDIO_PROMPTS[:intro])

    gather_response = @audio_interview_session.gather_initial_response
    expect(convert_twiml(gather_response)['Response']['Gather']).to_not be_nil

    practice_prompt_response = @audio_interview_session.practice_prompt
    expect(convert_twiml(practice_prompt_response)['Response']['Play']).to eq(AudioInterview::AUDIO_PROMPTS[:practice_prompt])

    continue_to_practice_record = @audio_interview_session.continue_to_practice_record
    expect(
      convert_twiml(continue_to_practice_record)['Response']['Gather'][0]['action']
    ).to eq(practice_record_audio_interview_twilio_index_url(step_progression_id: @step_progression.id, subdomain: 'integrations'))

    practice_redirect = @audio_interview_session.practice_redirect
    expect(convert_twiml(practice_redirect)['Response']['Redirect']).to eq(practice_playback_audio_interview_twilio_index_url(step_progression_id: @step_progression.id, subdomain: 'integrations'))

    practice_playback = @audio_interview_session.practice_playback
    expect(convert_twiml(practice_playback)['Response']['Play']).to eq([@audio_interview_practice_recording_url, AudioInterview::AUDIO_PROMPTS[:practice_playback], AudioInterview::AUDIO_PROMPTS[:practice_playback], AudioInterview::AUDIO_PROMPTS[:no_activity_end_call]])

    advance_response = @audio_interview_session.advance
    expect(convert_twiml(advance_response)['Response']['Redirect']).to eq(play_prompt_audio_interview_twilio_index_url(step_progression_id: @step_progression.id, audio_prompt_id: @audio_interview.current_audio_prompt.id, subdomain: 'integrations'))

    play_prompt = @audio_interview_session.play_prompt(@audio_prompt)
    expect(convert_twiml(play_prompt)['Response']['Play']).to eq(@audio_prompt.url)

    continue_to_record = @audio_interview_session.continue_to_record
    expect(convert_twiml(continue_to_record)['Response']['Gather'][0]['action']).to eq(continue_to_record_handler_audio_interview_twilio_index_url(audio_prompt_id: @audio_prompt.id, step_progression_id: @step_progression.id, subdomain: 'integrations'))

    record = @audio_interview_session.record(@audio_prompt)
    expect(convert_twiml(record)['Response']['Record']['action']).to eq(recording_handler_audio_interview_twilio_index_url(step_progression_id: @step_progression.id, audio_prompt_id: @audio_prompt.id, subdomain: 'integrations'))

    recording_finished = @audio_interview_session.recording_finished
    expect(convert_twiml(recording_finished)['Response']['Redirect']).to eq(advance_audio_interview_twilio_index_url(step_progression_id: @step_progression.id, subdomain: 'integrations'))

    advance_response2 = @audio_interview_session.advance
    expect(convert_twiml(advance_response2)['Response']['Redirect']).to eq(outro_audio_interview_twilio_index_url(step_progression_id: @step_progression.id, subdomain: 'integrations'))

    @step_progression.reload
    expect(@step_progression.completed_at).to_not be_nil

    outro_response = @audio_interview_session.outro
    expect(convert_twiml(outro_response)['Response']['Play']).to eq(AudioInterview::AUDIO_PROMPTS[:outro])
  end

  describe '#country_code' do
    it 'returns the first country code in the assessment' do
      @step1.assessment.supported_countries << Assessments::Country.new(code: 'CA')
      expect(@audio_interview_session.country_code).to eq('CA')
    end
  end

  describe '#locale' do
    it 'returns a normalized combination of assessment language code and country code' do
      @step1.assessment.language_code = 'en'
      @step1.assessment.supported_countries << Assessments::Country.new(code: 'US')

      expect(@audio_interview_session.locale).to eq('en-US')
    end

    it 'returns the default locale when combination of assessment language code and country code are not supported' do
      @step1.assessment.language_code = 'en'
      @step1.assessment.supported_countries << Assessments::Country.new(code: 'IT')

      expect(@audio_interview_session.locale).to eq('en')
    end

    it 'returns the fallback supported locale when only language code is supported' do
      @step1.assessment.language_code = 'fr'
      @step1.assessment.supported_countries << Assessments::Country.new(code: 'ZZ')

      expect(@audio_interview_session.locale).to eq('fr')
    end
  end

  context 'Feature flag #AUDIO_INTERVIEW_SELF_RECORD_0119' do
    before do
      @audio_prompt.update!(record_after_prompt: false)
      allow(FeatureFlag).to receive(:enabled?).with(Features::AUDIO_INTERVIEW_SELF_RECORD_0119, any_args).and_return(true)
      allow(FeatureFlag).to receive(:enabled?).with(Features::AUDIO_INTERVIEW_INTERNATIONAL, any_args).and_return(false)
      allow(FeatureFlag).to receive(:enabled?).with(Features::DRADIS_AUDIO_FILE_FLAG, any_args).and_return(false)
    end

    it '#practice_prompt redirects to continue_to_practice_record' do
      practice_prompt = @audio_interview_session.practice_prompt
      expect(convert_twiml(practice_prompt)['Response']['Redirect']).to eq(continue_to_practice_record_audio_interview_twilio_index_url(step_progression_id: @step_progression.id, subdomain: 'integrations'))
    end

    it '#start uses a different audio prompt' do
      start = @audio_interview_session.start
      expect(convert_twiml(start)['Response']['Play']).not_to eq(AudioInterview::AUDIO_PROMPTS[:intro])
    end

    it '#play_prompt redirects to continue_to_record' do
      practice_prompt = @audio_interview_session.play_prompt(@audio_prompt)
      expect(convert_twiml(practice_prompt)['Response']['Redirect']).to eq(advance_audio_interview_twilio_index_url(step_progression_id: @step_progression.id, subdomain: 'integrations'))
    end
  end

  context 'Feature flag #AUDIO_INTERVIEW_INTERNATIONAL' do
    describe '#international_enabled?' do
      it 'returns true when AUDIO_INTERVIEW_INTERNATIONAL is enabled for assessment' do
        Flipper[Features::AUDIO_INTERVIEW_INTERNATIONAL].enable_actor @step1.assessment
        expect(@audio_interview_session.international_enabled?).to be(true)
      end

      it 'returns false when AUDIO_INTERVIEW_INTERNATIONAL is not enabled for assessment' do
        expect(@audio_interview_session.international_enabled?).to be(false)
      end
    end

    describe '#phone_number_country_code' do
      it 'returns the country_code when AUDIO_INTERVIEW_INTERNATIONAL is enabled for assessment' do
        allow_any_instance_of(AudioInterviewSession).to receive(:international_enabled?).and_return(true)
        @step1.assessment.supported_countries << Assessments::Country.new(code: 'ZZ')
        @step_progression.attempt.user.country_code = 'FR'

        expect(@audio_interview_session.phone_number_country_code).to eq('ZZ')
      end

      it 'returns the users country_code when AUDIO_INTERVIEW_INTERNATIONAL feature is off' do
        allow_any_instance_of(AudioInterviewSession).to receive(:international_enabled?).and_return(false)
        @step1.assessment.supported_countries << Assessments::Country.new(code: 'ZZ')
        @step_progression.attempt.user.country_code = 'FR'

        expect(@audio_interview_session.phone_number_country_code).to eq('FR')
      end
    end

    describe '#international_prompts?' do
      it 'returns true when AUDIO_INTERVIEW_INTERNATIONAL feature flag is on and audio_prompts exist in locale file' do
        allow_any_instance_of(AudioInterviewSession).to receive(:international_enabled?).and_return(true)
        allow(I18n).to receive(:exists?).and_return(true)

        expect(@audio_interview_session.international_prompts?).to be(true)
      end

      it 'return false when AUDIO_INTERVIEW_INTERNATIONAL feature flag is off' do
        allow_any_instance_of(AudioInterviewSession).to receive(:international_enabled?).and_return(false)
        allow(I18n).to receive(:exists?).and_return(true)

        expect(@audio_interview_session.international_prompts?).to be(false)
      end

      it 'return false when audio_prompts does not exist in locale file' do
        allow_any_instance_of(AudioInterviewSession).to receive(:international_enabled?).and_return(true)
        allow(I18n).to receive(:exists?).and_return(false)

        expect(@audio_interview_session.international_prompts?).to be(false)
      end
    end

    describe '#translated_audio' do
      it 'returns audio prompts from locale file when AUDIO_INTERVIEW_INTERNATIONAL feature is on' do
        allow_any_instance_of(AudioInterviewSession).to receive(:international_prompts?).and_return(true)
        allow(I18n).to receive(:t)

        @audio_interview_session.translated_audio
        expect(I18n).to have_received(:t).with('audio_interview.audio_prompts', anything)
      end

      it 'returns audio prompts from hash literals feature is on' do
        allow_any_instance_of(AudioInterviewSession).to receive(:international_prompts?).and_return(false)
        allow(I18n).to receive(:t)

        expect(@audio_interview_session.translated_audio).to eq({})
        expect(I18n).not_to have_received(:t).with('audio_interview.audio_prompts', anything)
      end
    end
  end
end
