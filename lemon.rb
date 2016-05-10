require "yaml"

class User
  attr_accessor :has_notifications_disabled
  alias_method :has_notifications_disabled?, :has_notifications_disabled

  attr_accessor :has_favorited_notification_disabled
  alias_method :has_favorited_notification_disabled?, :has_favorited_notification_disabled

  attr_accessor :has_reposted_notification_disabled
  alias_method :has_reposted_notification_disabled?, :has_reposted_notification_disabled

  attr_accessor :has_followed_notification_disabled
  alias_method :has_followed_notification_disabled?, :has_followed_notification_disabled

  attr_accessor :has_replied_notification_disabled
  alias_method :has_replied_notification_disabled?, :has_replied_notification_disabled

  def self.find(id)
    found = Database.find("users", id)
    found && new(email: found[0], password: found[1], __save__: false, id: id)
  end

  attr_reader :id

  def initialize(email: nil, password: nil, __save__: true, id: nil)
    @password = password
    @signed_in = false

    if __save__
      @id = Database.insert("users", [email, password])
      Analytics.tag({name: "created_user"})
    else
      @id = id
    end
  end

  def ==(other)
    return false unless other.is_a?(User)
    return id == other.id if id || other.id

    email == other.email
  end

  def sign_in_via_password(password)
    @signed_in = (@password == password).tap do |success|
      Analytics.tag({name: "password_sign_in", success: success})
    end
  end

  def signed_in?
    @signed_in
  end

  def sign_out
    @signed_in = false
    Analytics.tag({name: "sign_out"})
  end

  def post(status_update)
    status_update.owner = self

    status_update.id = Database.insert("status_updates", [
      status_update.owner.id.to_s,
      status_update.reply_for && status_update.reply_for.id.to_s || "",
      status_update.repost_of && status_update.repost_of.id.to_s || "",
    ])

    Analytics.tag({name: "post_status_update", repost: false, reply: false})
  end

  def status_updates
    Database
      .where("status_updates") { |x| x[1][0] == id.to_s }
      .map do |row|
        id, values = row
        StatusUpdate.new(
          id: id,
          owner_id: values[0].to_i,
          reply_for_id: values[1].to_i,
          repost_of_id: values[2].to_i,
        )
      end
  end

  def follow(other_user)
    if other_user.blocking?(self)
      Analytics.tag({name: "follow_user_attempt_while_blocked"})
      return
    end

    Database.insert("follows", [
      id.to_s,
      other_user.id.to_s,
    ])

    Database.insert("notifications", [
      "followed_notification",
      id.to_s,
      other_user.id.to_s,
    ]) unless other_user.has_notifications_disabled? || other_user.has_followed_notification_disabled?

    Analytics.tag({name: "follow_user"})
  end

  def following
    Database
      .where("follows") { |x| x[1][0] == id.to_s }
      .map do |row|
        id, values = row
        Follow.new(
          id: id,
          user_id: values[0],
          other_user_id: values[1],
        )
      end
  end

  def following?(other_user)
    Database
      .where("follows") { |x| x[1] == [id.to_s, other_user.id.to_s] }
      .any?
  end

  def feed
    following
      .map(&:other_user)
      .map(&:status_updates)
      .reduce([], &:+).tap do |feed|
        Analytics.tag({name: "fetch_feed", count: feed.count})
      end
  end

  def favorite(status_update)
    Database.insert("favorites", [
      status_update.id.to_s,
      id.to_s,
    ])

    Database.insert("notifications", [
      "favorited_notification",
      id.to_s,
      status_update.id.to_s,
    ]) unless status_update.owner.has_notifications_disabled? || status_update.owner.has_favorited_notification_disabled?

    Analytics.tag({name: "favorite_status_update"})
  end

  def repost(status_update)
    post(StatusUpdate.new(repost_of: status_update))

    Database.insert("notifications", [
      "reposted_notification",
      id.to_s,
      status_update.id.to_s,
    ]) unless status_update.owner.has_notifications_disabled? || status_update.owner.has_reposted_notification_disabled?

    Analytics.tag({name: "post_status_update", repost: true, reply: false})
  end

  def notifications
    notifications = Database
      .where("notifications") do |x|
        (x[1][0] == "followed_notification" && x[1][2] == id.to_s) ||
        (x[1][0] == "favorited_notification" && StatusUpdate.find(x[1][2].to_i).owner_id == id) ||
        (x[1][0] == "replied_notification" && StatusUpdate.find(x[1][2].to_i).owner_id == id) ||
        (x[1][0] == "reposted_notification" && StatusUpdate.find(x[1][2].to_i).owner_id == id)
      end.map do |row|
        id, values = row
        kind = values[0]

        if kind == "followed_notification"
          {
            kind: kind,
            follower: User.find(values[1].to_i),
            user: User.find(values[2].to_i),
          }
        elsif kind == "favorited_notification"
          {
            kind: kind,
            favoriter: User.find(values[1].to_i),
            status_update: StatusUpdate.find(values[2].to_i),
          }
        elsif kind == "replied_notification"
          {
            kind: kind,
            sender: User.find(values[1].to_i),
            status_update: StatusUpdate.find(values[2].to_i),
            reply: StatusUpdate.find(values[3].to_i),
          }
        elsif kind == "reposted_notification"
          {
            kind: kind,
            reposter: User.find(values[1].to_i),
            status_update: StatusUpdate.find(values[2].to_i),
          }
        end
      end

    Analytics.tag({name: "fetch_notifications", count: notifications.count})
    notifications
  end

  def reply(status_update, reply)
    post(reply)

    reply.reply_for = status_update

    Database.insert("notifications", [
      "replied_notification",
      reply.owner.id.to_s,
      status_update.id.to_s,
      reply.id.to_s,
    ]) unless status_update.owner.has_notifications_disabled? || status_update.owner.has_replied_notification_disabled?

    Analytics.tag({name: "post_status_update", repost: false, reply: true})
  end

  def unfollow(other_user)
    Database
      .where("follows") { |x| x[1] == [id.to_s, other_user.id.to_s] }
      .each do |row|
        id, _ = row
        Database.delete("follows", id)
      end

    Analytics.tag({name: "unfollow_user"})
  end

  def block(other_user)
    @blocking ||= []
    @blocking << other_user
    other_user.unfollow(self)
    Analytics.tag({name: "block_user"})
  end

  def blocking?(other_user)
    @blocking ||= []
    @blocking.include?(other_user)
  end

  def has_notifications_disabled=(value)
    @has_notifications_disabled = value
    if value
      Analytics.tag({name: "disabled_notifications"})
    else
      Analytics.tag({name: "enabled_notifications"})
    end
  end

  def has_replied_notification_disabled=(value)
    @has_replied_notification_disabled = value
    if value
      Analytics.tag({name: "disabled_replied_notification"})
    else
      Analytics.tag({name: "enabled_replied_notification"})
    end
  end

  def has_followed_notification_disabled=(value)
    @has_followed_notification_disabled = value
    if value
      Analytics.tag({name: "disabled_followed_notification"})
    else
      Analytics.tag({name: "enabled_followed_notification"})
    end
  end

  def has_reposted_notification_disabled=(value)
    @has_reposted_notification_disabled = value
    if value
      Analytics.tag({name: "disabled_reposted_notification"})
    else
      Analytics.tag({name: "enabled_reposted_notification"})
    end
  end

  def has_favorited_notification_disabled=(value)
    @has_favorited_notification_disabled = value
    if value
      Analytics.tag({name: "disabled_favorited_notification"})
    else
      Analytics.tag({name: "enabled_favorited_notification"})
    end
  end
end

class Follow
  attr_reader :id, :user_id, :other_user_id

  def initialize(id: nil, user_id: nil, other_user_id: nil, user: nil, other_user: nil)
    @id = id
    @user = user
    @user_id = user_id unless user
    @other_user = other_user
    @other_user_id = other_user_id unless other_user
  end

  def user
    @user ||= user_id && User.find(user_id.to_i)
  end

  def other_user
    @other_user ||= other_user_id && User.find(other_user_id.to_i)
  end
end

class StatusUpdate
  attr_writer :owner, :reply_for, :repost_of
  attr_accessor :id, :owner_id, :reply_for_id, :repost_of_id

  def self.find(id)
    found = Database.find("status_updates", id)
    found && new(owner_id: found[0].to_i, reply_for_id: found[1].to_i, repost_of_id: found[2].to_i, id: id)
  end

  def initialize(owner_id: nil, reply_for_id: nil, repost_of_id: nil, repost_of: nil, id: nil)
    @id = id
    @owner_id = owner_id
    @reply_for_id = reply_for_id
    @repost_of = repost_of
    @repost_of_id = repost_of_id unless repost_of
  end

  def ==(other)
    return false unless other.is_a?(StatusUpdate)
    return id == other.id if id || other.id

    equality_criteria == other.equality_criteria
  end

  def equality_criteria
    [
      owner_id || (owner && owner.id),
      reply_for_id || (reply_for && reply_for.id),
      repost_of_id || (repost_of && repost_of.id),
    ]
  end

  def owner
    @owner ||= owner_id && User.find(owner_id)
  end

  def reply_for
    @reply_for ||= reply_for_id && StatusUpdate.find(reply_for_id)
  end

  def repost_of
    @repost_of ||= repost_of_id && StatusUpdate.find(repost_of_id)
  end

  def favorited_by
    Database
      .where("favorites") { |x| x[1][0] == id.to_s }
      .map do |row|
        _, values = row
        User.find(values[1].to_i)
      end
  end
end

module Analytics
  extend self

  def tag(event)
    puts "fake analytics: tagged #{event.inspect}"
  end
end

module Database
  extend self

  def insert(table, values)
    unless values.all? { |v| v.is_a?(String) }
      fail ArgumentError, "All values have to be strings: #{values}"
    end

    filename = "#{ENV["HOME"]}/.lemon/database/#{table}.yml"
    table = YAML.load_file(filename) rescue []
    id = table.count
    table << [id, values]
    File.open(filename, "w") { |f| f.write(table.to_yaml) }

    id
  end

  def find(table, id)
    filename = "#{ENV["HOME"]}/.lemon/database/#{table}.yml"
    table = YAML.load_file(filename) rescue []
    found = table.find { |row| row[0] == id }
    found && found[1]
  end

  def where(table, &block)
    filename = "#{ENV["HOME"]}/.lemon/database/#{table}.yml"
    table = YAML.load_file(filename) rescue []
    table.select(&block)
  end

  def delete(table, id)
    filename = "#{ENV["HOME"]}/.lemon/database/#{table}.yml"
    table = YAML.load_file(filename) rescue []
    table = table.reject { |x| x[0] == id }
    File.open(filename, "w") { |f| f.write(table.to_yaml) }
  end

  def _clear(table)
    filename = "#{ENV["HOME"]}/.lemon/database/#{table}.yml"
    `rm #{filename}`
  end
end

RSpec.configure do |c|
  c.before(:suite) {
    Database._clear("users")
    Database._clear("status_updates")
    Database._clear("follows")
    Database._clear("notifications")
    Database._clear("favorites")
  }
end

describe User do
  let(:email) { "john@example.org" }

  let(:correct_password) { "correct password" }
  let(:incorrect_password) { "incorrect password" }

  let(:user) do
    u = User.new(email: email, password: correct_password)
    User.find(u.id)
  end

  let(:other_user) do
    u = User.new(
      email: "sarah@example.org",
      password: "welcome",
    )
    User.find(u.id)
  end

  let(:another_user) do
    u = User.new(
      email: "jonatan@example.org",
      password: "welcome",
    )
    User.find(u.id)
  end

  let(:status_update) { StatusUpdate.new }
  let(:another_status_update) { StatusUpdate.new }

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
        u = User.new(
          email: "james@example.org",
          password: "welcome",
        )
        User.find(u.id)
      end

      it "does not follow other user" do
        expect(user).not_to be_following(other_user)
      end
    end

    context "when already following some users" do
      let(:already_following_user) do
        u = User.new(
          email: "blake@example.org",
          password: "welcome",
        )
        User.find(u.id)
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
    let(:status_update) { StatusUpdate.new }

    before do
      other_user.post(status_update)
    end

    it "favorites status update" do
      user.favorite(status_update)
      expect(status_update.favorited_by).to include(user)
    end

    it "is not considered as favorited by some other user" do
      user.favorite(status_update)
      expect(status_update.favorited_by).not_to include(other_user)
    end

    context "when user did not favorite this status update" do
      it "is not considered favorited by this user" do
        expect(status_update.favorited_by).not_to include(user)
      end
    end

    context "when status update is favorited by multiple users" do
      before do
        user.favorite(status_update)
        other_user.favorite(status_update)
      end

      it "is considered favorited by all of such users" do
        [user, other_user].each do |user|
          expect(status_update.favorited_by).to include(user)
        end
      end
    end
  end

  describe "can see other users who favorited given status update" do
    before do
      another_user.post(status_update)
    end

    context "when nobody have favorited" do
      it "sees no users" do
        expect(status_update.favorited_by).to be_empty
      end
    end

    context "when some users have favorited" do
      before do
        user.favorite(status_update)
        other_user.favorite(status_update)
      end

      it "sees all such users" do
        [user, other_user].each do |user|
          expect(status_update.favorited_by).to include(user)
        end
      end
    end
  end

  describe "can repost a status update from the feed" do
    before do
      user.post(status_update)
      other_user.repost(status_update)
    end

    subject(:repost) { other_user.status_updates.last }

    it "posts new status update" do
      expect(repost.repost_of).to eq(status_update)
    end

    it "is not the same status update" do
      expect(repost).not_to eq(status_update)
    end
  end

  describe "is subscribed to favorites of own status updates" do
    context "when status update is not own" do
      before do
        other_user.post(status_update)
        another_user.favorite(status_update)
      end

      it "does not appear in the notifications" do
        expect(user.notifications).to be_empty
      end
    end

    context "when status update is own" do
      before do
        user.post(status_update)
      end

      context "when status update is not favorited" do
        it "does not change notifications" do
          expect(user.notifications).to be_empty
        end
      end

      context "when status update is favorited" do
        before do
          other_user.favorite(status_update)
        end

        it "creates an event in user's notifications" do
          expect(user.notifications).to include({
            kind: "favorited_notification",
            favoriter: other_user,
            status_update: status_update,
          })
        end

        context "when favorited by more users" do
          before do
            another_user.favorite(status_update)
          end

          it "receives another notification" do
            expect(user.notifications).to include({
              kind: "favorited_notification",
              favoriter: another_user,
              status_update: status_update,
            })
          end

          it "still preserves old notifications" do
            expect(user.notifications).to include({
              kind: "favorited_notification",
              favoriter: other_user,
              status_update: status_update,
            })
          end
        end
      end
    end
  end

  describe "is subscribed to reposts of own status updates" do
    context "when status update is not own" do
      before do
        other_user.post(status_update)
        another_user.repost(status_update)
      end

      it "does not send any notification to this user" do
        expect(user.notifications).to be_empty
      end
    end

    context "when status update is own" do
      before do
        user.post(status_update)
      end

      context "when reposted by one user" do
        before do
          other_user.repost(status_update)
        end

        it "sends repost notification to this user" do
          expect(user.notifications).to include({
            kind: "reposted_notification",
            reposter: other_user,
            status_update: status_update,
          })
        end

        context "when reposted by more users" do
          before do
            another_user.repost(status_update)
          end

          it "sends repost notification to this user" do
            expect(user.notifications).to include({
              kind: "reposted_notification",
              reposter: another_user,
              status_update: status_update,
            })
          end

          it "preserves previous notifications for this user" do
            expect(user.notifications).to include({
              kind: "reposted_notification",
              reposter: other_user,
              status_update: status_update,
            })
          end
        end
      end
    end
  end

  describe "is subscribed to followed notifications" do
    context "when follow does not involve this user" do
      before do
        other_user.follow(another_user)
      end

      it "does not send notification to this user" do
        expect(user.notifications).to be_empty
      end
    end

    context "when followed by other user" do
      before do
        other_user.follow(user)
      end

      it "sends followed notification to this user" do
        expect(user.notifications).to include({
          kind: "followed_notification",
          follower: other_user,
          user: user,
        })
      end

      context "when followed by many users" do
        before do
          another_user.follow(user)
        end

        it "sends followed notification to this user" do
          expect(user.notifications).to include({
            kind: "followed_notification",
            follower: another_user,
            user: user,
          })
        end

        it "preserves previous notifications for this user" do
          expect(user.notifications).to include({
            kind: "followed_notification",
            follower: other_user,
            user: user,
          })
        end
      end
    end
  end

  describe "can reply to status update" do
    before do
      other_user.post(status_update)
    end

    subject(:reply) { StatusUpdate.new }

    it "posts a reply" do
      user.reply(status_update, reply)
      expect(user.status_updates).to include(reply)
    end

    it "posts a reply to that status update" do
      user.reply(status_update, reply)
      expect(reply.reply_for).to eq(status_update)
    end

    it "posts a reply to that and only to that status update" do
      user.reply(status_update, reply)
      expect(reply.reply_for).not_to eq(another_status_update)
    end
  end

  describe "is subscribed to reply notifications" do
    context "when this user is not involved" do
      before do
        other_user.post(status_update)
        another_user.reply(status_update, StatusUpdate.new)
      end

      it "does not send any notifications to this user" do
        expect(user.notifications).to be_empty
      end
    end

    context "when user owns status update that is replied to" do
      let(:reply) { StatusUpdate.new }

      before do
        user.post(status_update)
        other_user.reply(status_update, reply)
      end

      it "sends reply notification to this user" do
        expect(user.notifications).to include({
          kind: "replied_notification",
          sender: other_user,
          status_update: status_update,
          reply: reply,
        })
      end

      context "when multiple users have replied" do
        let(:another_reply) { StatusUpdate.new }

        before do
          another_user.reply(status_update, another_reply)
        end

        it "sends reply notification to this user" do
          expect(user.notifications).to include({
            kind: "replied_notification",
            sender: another_user,
            status_update: status_update,
            reply: another_reply,
          })
        end

        it "preserves previous notifications for this user" do
          expect(user.notifications).to include({
            kind: "replied_notification",
            sender: other_user,
            status_update: status_update,
            reply: reply,
          })
        end
      end
    end
  end

  describe "can disable all notifications" do
    before do
      user.has_notifications_disabled = true
    end

    it "does not send favorited notification" do
      user.post(status_update)
      other_user.favorite(status_update)
      expect(user.notifications).to be_empty
    end

    it "does not send reposted notification" do
      user.post(status_update)
      other_user.repost(status_update)
      expect(user.notifications).to be_empty
    end

    it "does not send followed notification" do
      other_user.follow(user)
      expect(user.notifications).to be_empty
    end

    it "does not send replied notification" do
      user.post(status_update)
      other_user.reply(status_update, StatusUpdate.new)
      expect(user.notifications).to be_empty
    end
  end

  describe "can disable favorited notification" do
    before do
      user.has_favorited_notification_disabled = true
    end

    it "does not send favorited notification" do
      user.post(status_update)
      other_user.favorite(status_update)
      expect(user.notifications).to be_empty
    end

    it "sends reposted notification" do
      user.post(status_update)
      other_user.repost(status_update)
      expect(user.notifications).not_to be_empty
    end

    it "sends followed notification" do
      other_user.follow(user)
      expect(user.notifications).not_to be_empty
    end

    it "sends replied notification" do
      user.post(status_update)
      other_user.reply(status_update, StatusUpdate.new)
      expect(user.notifications).not_to be_empty
    end
  end

  describe "can disable reposted notification" do
    before do
      user.has_reposted_notification_disabled = true
    end

    it "sends favorited notification" do
      user.post(status_update)
      other_user.favorite(status_update)
      expect(user.notifications).not_to be_empty
    end

    it "does not send reposted notification" do
      user.post(status_update)
      other_user.repost(status_update)
      expect(user.notifications).to be_empty
    end

    it "sends followed notification" do
      other_user.follow(user)
      expect(user.notifications).not_to be_empty
    end

    it "sends replied notification" do
      user.post(status_update)
      other_user.reply(status_update, StatusUpdate.new)
      expect(user.notifications).not_to be_empty
    end
  end

  describe "can disable followed notification" do
    before do
      user.has_followed_notification_disabled = true
    end

    it "sends favorited notification" do
      user.post(status_update)
      other_user.favorite(status_update)
      expect(user.notifications).not_to be_empty
    end

    it "sends reposted notification" do
      user.post(status_update)
      other_user.repost(status_update)
      expect(user.notifications).not_to be_empty
    end

    it "does not send followed notification" do
      other_user.follow(user)
      expect(user.notifications).to be_empty
    end

    it "sends replied notification" do
      user.post(status_update)
      other_user.reply(status_update, StatusUpdate.new)
      expect(user.notifications).not_to be_empty
    end
  end

  describe "can disable replied notification" do
    before do
      user.has_replied_notification_disabled = true
    end

    it "sends favorited notification" do
      user.post(status_update)
      other_user.favorite(status_update)
      expect(user.notifications).not_to be_empty
    end

    it "sends reposted notification" do
      user.post(status_update)
      other_user.repost(status_update)
      expect(user.notifications).not_to be_empty
    end

    it "sends followed notification" do
      other_user.follow(user)
      expect(user.notifications).not_to be_empty
    end

    it "does not send replied notification" do
      user.post(status_update)
      other_user.reply(status_update, StatusUpdate.new)
      expect(user.notifications).to be_empty
    end
  end

  describe "can unfollow another user" do
    before do
      user.follow(other_user)
    end

    it "stops following" do
      user.unfollow(other_user)
      expect(user).not_to be_following(other_user)
    end

    context "when tried to follow multiple times" do
      before do
        user.follow(other_user)
        user.follow(other_user)
      end

      it "still stops following" do
        user.unfollow(other_user)
        expect(user).not_to be_following(other_user)
      end
    end
  end

  describe "can block other user" do
    it "is not blocking unless blocked" do
      expect(user).not_to be_blocking(other_user)
    end

    it "blocks other user" do
      user.block(other_user)
      expect(user).to be_blocking(other_user)
    end

    it "does not block any other user" do
      user.block(other_user)
      expect(user).not_to be_blocking(another_user)
    end

    it "is possible to block multiple users" do
      user.block(other_user)
      user.block(another_user)
      [other_user, another_user].each do |blocked_user|
        expect(user).to be_blocking(blocked_user)
      end
    end
  end

  describe "can not follow when blocked" do
    context "when was not following before block" do
      before do
        other_user.block(user)
      end

      it "disallows following that user" do
        user.follow(other_user)
        expect(user).not_to be_following(other_user)
      end

      it "does not affect ability to follow other users" do
        user.follow(another_user)
        expect(user).to be_following(another_user)
      end

      it "does not affect ability of other users to follow that user" do
        another_user.follow(other_user)
        expect(another_user).to be_following(other_user)
      end
    end

    context "when was following before block" do
      before do
        user.follow(other_user)
        other_user.block(user)
      end

      it "unfollows that user" do
        expect(user).not_to be_following(other_user)
      end
    end
  end
end
