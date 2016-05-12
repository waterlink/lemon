require "./lemon"

class User
  def notifications__isolated__
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
end

RSpec.configure do |c|
  c.before do
    Database._clear("users")
    Database._clear("notifications")
  end
end

describe User do
  describe "#notifications" do
    it "looks like it loads some notifications from the database" do
      user = User.new(email: "john@example.org", password: "welcome")
      Database.insert("notifications", ["followed_notification", "986", user.id.to_s])

      notifications = user.notifications__isolated__

      expect(notifications.count).to eq(1)
    end

    it "loads followed notifications with correct kind" do
      user = User.new(email: "john@example.org", password: "welcome")
      Database.insert("notifications", ["followed_notification", "986", user.id.to_s])

      notifications = user.notifications__isolated__

      expect(notifications[0][:kind]).to eq("followed_notification")
    end

    it "loads followed notifications with correct follower" do
      user = User.new(email: "john@example.org", password: "welcome")
      follower = User.new(email: "sarah@example.org", password: "welcome")
      Database.insert("notifications", ["followed_notification", follower.id.to_s, user.id.to_s])

      notifications = user.notifications__isolated__

      expect(notifications[0][:follower]).to eq(follower)
    end
  end
end
