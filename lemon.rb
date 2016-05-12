require "yaml"
require "json"

class User
  attr_reader :has_notifications_disabled
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
    found && load(id, found)
  end

  def self.load(id, found)
    new(
      __save__: false,
      id: id,
      email: found[0],
      password: found[1],
      has_notifications_disabled: found[2] == "true",
      has_replied_notification_disabled: found[3] == "true",
      has_followed_notification_disabled: found[4] == "true",
      has_reposted_notification_disabled: found[5] == "true",
      has_favorited_notification_disabled: found[6] == "true",
    )
  end

  attr_reader :id, :email

  def initialize(email: nil, password: nil, __save__: true, id: nil,
    has_notifications_disabled: false, has_favorited_notification_disabled: false,
    has_reposted_notification_disabled: false, has_followed_notification_disabled: false,
    has_replied_notification_disabled: false)

    @email = email
    @password = password
    @signed_in = false

    @has_notifications_disabled = has_notifications_disabled
    @has_replied_notification_disabled = has_replied_notification_disabled
    @has_followed_notification_disabled = has_followed_notification_disabled
    @has_reposted_notification_disabled = has_reposted_notification_disabled
    @has_favorited_notification_disabled = has_favorited_notification_disabled

    if __save__
      @id = Database.insert("users", [
        @email,
        @password,
        has_notifications_disabled.to_s,
        has_replied_notification_disabled.to_s,
        has_followed_notification_disabled.to_s,
        has_reposted_notification_disabled.to_s,
        has_favorited_notification_disabled.to_s,
      ])

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
    Database.insert("blocks", [
      id.to_s,
      other_user.id.to_s,
    ])

    other_user.unfollow(self)

    Analytics.tag({name: "block_user"})
  end

  def blocking?(other_user)
    Database
      .where("blocks") { |x| x[1][0] == id.to_s && x[1][1] == other_user.id.to_s }
      .any?
  end

  def has_notifications_disabled=(value)
    @has_notifications_disabled = value

    Database.update("users", id, [
      email,
      @password,
      has_notifications_disabled.to_s,
      has_replied_notification_disabled.to_s,
      has_followed_notification_disabled.to_s,
      has_reposted_notification_disabled.to_s,
      has_favorited_notification_disabled.to_s,
    ])

    if value
      Analytics.tag({name: "disabled_notifications"})
    else
      Analytics.tag({name: "enabled_notifications"})
    end
  end

  def has_replied_notification_disabled=(value)
    @has_replied_notification_disabled = value

    Database.update("users", id, [
      email,
      @password,
      has_notifications_disabled.to_s,
      has_replied_notification_disabled.to_s,
      has_followed_notification_disabled.to_s,
      has_reposted_notification_disabled.to_s,
      has_favorited_notification_disabled.to_s,
    ])

    if value
      Analytics.tag({name: "disabled_replied_notification"})
    else
      Analytics.tag({name: "enabled_replied_notification"})
    end
  end

  def has_followed_notification_disabled=(value)
    @has_followed_notification_disabled = value

    Database.update("users", id, [
      email,
      @password,
      has_notifications_disabled.to_s,
      has_replied_notification_disabled.to_s,
      has_followed_notification_disabled.to_s,
      has_reposted_notification_disabled.to_s,
      has_favorited_notification_disabled.to_s,
    ])

    if value
      Analytics.tag({name: "disabled_followed_notification"})
    else
      Analytics.tag({name: "enabled_followed_notification"})
    end
  end

  def has_reposted_notification_disabled=(value)
    @has_reposted_notification_disabled = value

    Database.update("users", id, [
      email,
      @password,
      has_notifications_disabled.to_s,
      has_replied_notification_disabled.to_s,
      has_followed_notification_disabled.to_s,
      has_reposted_notification_disabled.to_s,
      has_favorited_notification_disabled.to_s,
    ])

    if value
      Analytics.tag({name: "disabled_reposted_notification"})
    else
      Analytics.tag({name: "enabled_reposted_notification"})
    end
  end

  def has_favorited_notification_disabled=(value)
    @has_favorited_notification_disabled = value

    Database.update("users", id, [
      email,
      @password,
      has_notifications_disabled.to_s,
      has_replied_notification_disabled.to_s,
      has_followed_notification_disabled.to_s,
      has_reposted_notification_disabled.to_s,
      has_favorited_notification_disabled.to_s,
    ])

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
    Database.insert("tagged_events", [event.to_json])
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
    id = (table.map { |row| id = row[0] }.max || 0) + 1
    table << [id, values]
    File.open(filename, "w") { |f| f.write(table.to_yaml) }

    id
  end

  def update(table, id, values)
    unless values.all? { |v| v.is_a?(String) }
      fail ArgumentError, "All values have to be strings: #{values}"
    end

    filename = "#{ENV["HOME"]}/.lemon/database/#{table}.yml"
    table = YAML.load_file(filename) rescue []

    table = table.map do |row|
      if row[0] == id
        [id, values]
      else
        row
      end
    end

    File.open(filename, "w") { |f| f.write(table.to_yaml) }
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
    `rm #{filename}` if File.exists?(filename)
  end
end
