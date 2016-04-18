class User
  def initialize(email: nil, password: nil)
    @password = password
    @signed_in = false
  end

  def sign_in_via_password(password)
    @signed_in = @password == password
  end

  def signed_in?
    @signed_in
  end

  def sign_out
    @signed_in = false
  end

  def post(status_update)
    @status_updates ||= []
    @status_updates << status_update
  end

  def status_updates
    @status_updates ||= []
  end

  def follow(other_user)
    @following ||= []
    @following << other_user
  end

  def following?(other_user)
    @following ||= []
    @following.include?(other_user)
  end

  def feed
    @following ||= []
    @following
      .map(&:status_updates)
      .reduce([], &:+)
  end
end

class StatusUpdate
end

describe User do
  let(:email) { "john@example.org" }

  let(:correct_password) { "correct password" }
  let(:incorrect_password) { "incorrect password" }

  let(:user) do
    User.new(email: email, password: correct_password)
  end

  let(:other_user) do
    User.new(
      email: "sarah@example.org",
      password: "welcome",
    )
  end

  let(:status_update) { StatusUpdate.new }

  describe "can sign in" do
    it "is signed in" do
      user.sign_in_via_password(correct_password)
      expect(user).to be_signed_in
    end

    context "when password is not right" do
      it "is not signed in" do
        user.sign_in_via_password(incorrect_password)
        expect(user).not_to be_signed_in
      end
    end
  end

  describe "can sign out" do
    before do
      user.sign_in_via_password(correct_password)
    end

    it "signs user out" do
      user.sign_out
      expect(user).not_to be_signed_in
    end
  end

  describe "can post a status update" do
    it "posts new status update" do
      user.post(status_update)
      expect(user.status_updates).to include(status_update)
    end

    context "when already have some updates" do
      let(:old_status_update) { StatusUpdate.new }

      before do
        user.post(old_status_update)
      end

      it "posts new status update" do
        user.post(status_update)
        expect(user.status_updates).to include(status_update)
      end

      it "contains old status updates" do
        user.post(status_update)
        expect(user.status_updates).to include(old_status_update)
      end
    end
  end

  describe "can follow other user" do
    it "follows other user" do
      user.follow(other_user)
      expect(user).to be_following(other_user)
    end

    context "when user have not followed other user yet" do
      let(:other_user) do
        User.new(
          email: "james@example.org",
          password: "welcome",
        )
      end

      it "does not follow other user" do
        expect(user).not_to be_following(other_user)
      end
    end

    context "when already following some users" do
      let(:already_following_user) do
        User.new(
          email: "blake@example.org",
          password: "welcome",
        )
      end

      before do
        user.follow(already_following_user)
      end

      it "follows other user" do
        user.follow(other_user)
        expect(user).to be_following(other_user)
      end

      it "follows previously followed users" do
        user.follow(other_user)
        expect(user).to be_following(already_following_user)
      end
    end
  end

  describe "can read status update feed from followed users" do
    context "when followin one user" do
      before do
        user.follow(other_user)
      end

      it "sees a status update from other user in the feed" do
        other_user.post(status_update)
        expect(user.feed).to include(status_update)
      end
    end

    context "when not following anyone" do
      it "has empty feed" do
        other_user.post(status_update)
        expect(user.feed).to be_empty
      end
    end

    context "when following multiple users" do
      let(:another_user) do
        User.new(
          email: "jonatan@example.org",
          password: "welcome",
        )
      end

      let(:another_status_update) { StatusUpdate.new }

      before do
        user.follow(other_user)
        user.follow(another_user)
      end

      it "sees status updates from all such users in the feed" do
        other_user.post(status_update)
        another_user.post(another_status_update)

        [status_update, another_status_update].each do |status_update|
          expect(user.feed).to include(status_update)
        end
      end
    end
  end

  describe "can favorite other user status update" do
  end
end
