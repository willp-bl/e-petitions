require 'rails_helper'

RSpec.describe Admin::PetitionsController, type: :controller do
  include ActiveJob::TestHelper

  before :each do
    creator_signature = FactoryGirl.create(:signature, :email => 'john@example.com')
    @petition = FactoryGirl.create(:sponsored_petition, :creator_signature => creator_signature)
  end

  describe "not logged in" do
    describe "GET 'threshold'" do
      it "redirects to the login page" do
        get :threshold
        expect(response).to redirect_to("https://petition.parliament.uk/admin/login")
      end
    end

    describe "GET 'index'" do
      it "redirects to the login page" do
        get :index
        expect(response).to redirect_to("https://petition.parliament.uk/admin/login")
      end
    end

    describe "GET 'show'" do
      it "redirects to the login page" do
        get :show, :id => @petition.id
        expect(response).to redirect_to("https://petition.parliament.uk/admin/login")
      end
    end
  end

  context "logged in as moderator user but need to reset password" do
    before :each do
      @user = FactoryGirl.create(:moderator_user, :force_password_reset => true)
      login_as(@user)
    end

    it "redirects to edit profile page" do
      expect(@user.has_to_change_password?).to be_truthy
      get :show, :id => @petition.id
      expect(response).to redirect_to("https://petition.parliament.uk/admin/profile/#{@user.id}/edit")
    end
  end

  describe "logged in as moderator user" do
    before :each do
      @user = FactoryGirl.create(:moderator_user)
      login_as(@user)

      @p1 = FactoryGirl.create(:open_petition)
      @p1.update_attribute(:signature_count, 11)
      @p2 = FactoryGirl.create(:open_petition)
      @p2.update_attribute(:signature_count, 10)
      @p3 = FactoryGirl.create(:open_petition)
      @p3.update_attribute(:signature_count, 9)
      @p4 = FactoryGirl.create(:closed_petition)
      @p4.update_attribute(:signature_count, 20)

      allow(Site).to receive(:threshold_for_debate).and_return(10)
    end

    it "returns all petitions that have more than the threshold number of signatures in ascending count order" do
      get :threshold
      expect(assigns[:petitions]).to eq([@p2, @p1, @p4])
    end

    it "assigns petition" do
      get :edit_response, :id => @p1.id
      expect(assigns[:petition]).to eq(@p1)
    end

    context "update_response" do
      def do_patch(options = {})
        patch :update_response, :id => @p1.id, :petition => { :response => 'Doh!', :response_summary => 'Summary', :email_signees => '1'}.merge(options)
      end

      it "updates response and stamp the 'government_response' email requested receipt timestamp when email signees flag is true" do
        do_patch
        assert_enqueued_jobs 1
        expect(response).to redirect_to("https://petition.parliament.uk/admin/petitions")
        @p1.reload
        expect(@p1.response).to eq('Doh!')
        expect(@p1.get_email_requested_at_for('government_response')).not_to be_nil
      end

      it "updates response and not stamp the 'governent_rsponse' email requested receipt timestamp when email signees flag is false" do
        do_patch(:email_signees => '0')
        assert_enqueued_jobs 0
        @p1.reload
        expect(@p1.response).to eq('Doh!')
        expect(@p1.get_email_requested_at_for('government_response')).to be_nil
      end

      it "doest not update response or stamp the 'government_response' email requested receipt timestamp if there is a validation error" do
        do_patch(:response => '', :email_signees => '1')
        assert_enqueued_jobs 0
        expect(response).to be_success
        @p1.reload
        expect(@p1.get_email_requested_at_for('government_response')).to be_nil
      end

      context "email out threshold update response" do
        before do
          signature =  FactoryGirl.create(:pending_signature,
                          name: 'Jason',
                          email: 'jason@example.com',
                          notify_by_email: true
                        )

          @petition = FactoryGirl.create(:open_petition,
                        action: 'Make me the PM',
                        creator_signature: signature
                      )

          3.times do |i|
            attributes = {
              name: "Jason #{i}",
              email: "jason_valid_notify_#{i}@example.com",
              notify_by_email: true,
              petition: @petition
            }

            s = FactoryGirl.create(:pending_signature, attributes)
            s.validate!
          end

          2.times do |i|
            attributes = {
              name: "Jason #{i+3}",
              email: "jason_valid_#{i}@example.com",
              notify_by_email: false,
              petition: @petition
            }

            s = FactoryGirl.create(:pending_signature, attributes)
            s.validate!
          end

          2.times do |i|
            attributes = {
              name: "Jason #{i+5}",
              email: "jason_invalid_#{i}@example.com",
              notify_by_email: true,
              petition: @petition
            }

            FactoryGirl.create(:pending_signature, attributes)
          end

          @petition.reload
        end

        it "queues a job to process the emails" do
          assert_enqueued_jobs 1 do
            patch :update_response, :id => @petition.id, :petition => { :response => 'Doh!', :response_summary => 'Summary', :email_signees => '1'}
          end
        end

        it "stamps the 'government_response' email sent receipt on each signature when the job runs" do
          perform_enqueued_jobs do
            patch :update_response, :id => @petition.id, :petition => { :response => 'Doh!', :response_summary => 'Summary', :email_signees => '1'}
            @petition.reload
            petition_timestamp = @petition.get_email_requested_at_for('government_response')
            expect(petition_timestamp).not_to be_nil
            @petition.signatures.validated.notify_by_email.each do |signature|
              expect(signature.get_email_sent_at_for('government_response')).to eq(petition_timestamp)
            end
          end
        end

        it "emails out to the validated signees who have opted in when the delayed job runs" do
          ActionMailer::Base.deliveries.clear
          perform_enqueued_jobs do
            patch :update_response, :id => @petition.id, :petition => { :response => 'Doh!', :response_summary => 'Summary', :email_signees => '1'}
            expect(ActionMailer::Base.deliveries.length).to eq(4)
            expect(ActionMailer::Base.deliveries.map(&:to)).to eq([
              ["jason@example.com"],
              ["jason_valid_notify_0@example.com"],
              ["jason_valid_notify_1@example.com"],
              ["jason_valid_notify_2@example.com"]
            ])
            expect(ActionMailer::Base.deliveries[0].subject).to match(/The petition 'Make me the PM' has reached 6 signatures/)
            expect(ActionMailer::Base.deliveries[1].subject).to match(/The petition 'Make me the PM' has reached 6 signatures/)
            expect(ActionMailer::Base.deliveries[2].subject).to match(/The petition 'Make me the PM' has reached 6 signatures/)
            expect(ActionMailer::Base.deliveries[3].subject).to match(/The petition 'Make me the PM' has reached 6 signatures/)
          end
        end
      end
    end

    context "updating scheduled debate date" do
      let!(:petition) { FactoryGirl.create(:open_petition) }

      context "edit_scheduled_debate_date" do
        it "renders a view to update scheduled debate date" do
          get :edit_scheduled_debate_date, :id => petition.id
          expect(response).to render_template("edit_scheduled_debate_date")
        end

        shared_examples_for 'trying to view edit scheduled debate date view for a petition in the wrong state' do
          it 'raises a 404 error' do
            expect {
              get :edit_scheduled_debate_date, id: petition.id
            }.to raise_error ActiveRecord::RecordNotFound
          end
        end

        describe 'for a pending petition' do
          before { petition.update_column(:state, Petition::PENDING_STATE) }
          it_behaves_like 'trying to view edit scheduled debate date view for a petition in the wrong state'
        end

        describe 'for a validated petition' do
          before { petition.update_column(:state, Petition::VALIDATED_STATE) }
          it_behaves_like 'trying to view edit scheduled debate date view for a petition in the wrong state'
        end

        describe 'for a sponsored petition' do
          before { petition.update_column(:state, Petition::SPONSORED_STATE) }
          it_behaves_like 'trying to view edit scheduled debate date view for a petition in the wrong state'
        end

        describe 'for a rejected petition' do
          before { petition.update_column(:state, Petition::REJECTED_STATE) }
          it_behaves_like 'trying to view edit scheduled debate date view for a petition in the wrong state'
        end

        describe 'for a hidden petition' do
          before { petition.update_column(:state, Petition::HIDDEN_STATE) }
          it_behaves_like 'trying to view edit scheduled debate date view for a petition in the wrong state'
        end
      end

      context "update_scheduled_debate_date" do
        it "updates scheduled debate date with valid param" do
          patch :update_scheduled_debate_date, :id => @p1.id, :petition => { :scheduled_debate_date => '06/12/2015' }
          @p1.reload
          expect(@p1.scheduled_debate_date).to eq("06/12/2015".to_date)
        end

        shared_examples_for 'trying to view update scheduled debate date for a petition in the wrong state' do
          it 'raises a 404 error' do
            expect {
              get :edit_scheduled_debate_date, id: petition.id
            }.to raise_error ActiveRecord::RecordNotFound
          end
        end

        describe 'for a pending petition' do
          before { petition.update_column(:state, Petition::PENDING_STATE) }
          it_behaves_like 'trying to view update scheduled debate date for a petition in the wrong state'
        end

        describe 'for a validated petition' do
          before { petition.update_column(:state, Petition::VALIDATED_STATE) }
          it_behaves_like 'trying to view update scheduled debate date for a petition in the wrong state'
        end

        describe 'for a sponsored petition' do
          before { petition.update_column(:state, Petition::SPONSORED_STATE) }
          it_behaves_like 'trying to view update scheduled debate date for a petition in the wrong state'
        end

        describe 'for a rejected petition' do
          before { petition.update_column(:state, Petition::REJECTED_STATE) }
          it_behaves_like 'trying to view update scheduled debate date for a petition in the wrong state'
        end

        describe 'for a hidden petition' do
          before { petition.update_column(:state, Petition::HIDDEN_STATE) }
          it_behaves_like 'trying to view update scheduled debate date for a petition in the wrong state'
        end
      end
    end
  end

  describe "logged in as sysadmin" do
    before :each do
      @user = FactoryGirl.create(:sysadmin_user)
      login_as(@user)
    end

    context "index" do
      let(:petitions) { double.as_null_object }

      before do
        allow(Petition).to receive(:selectable).and_return(petitions)
      end

      it "shows all selectable petitions" do
        expect(Petition).to receive(:selectable).and_return(petitions)
        get :index
      end
    end

    context "show" do
      it "assigns petition successfully" do
        get :show, :id => @petition.id
        expect(assigns(:petition)).to eq(@petition)
      end
    end
  end
end
