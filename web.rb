require "sinatra"
require "sinatra/cookies"
require "erb"
require "securerandom"
require "time"

require "./lemon"

module Sinatra
  module LayoutRender
    def render_with_layout(name, layout = "layout.html")
      @__layout_render__name = name
      render(:erb, File.read("./#{layout}.erb"))
    end

    def layout_yield
      partial(@__layout_render__name)
    end

    def partial(name)
      render(:erb, File.read("./#{name}.erb"))
    end
  end

  helpers LayoutRender
end

module Sinatra
  module Auth
    def authenticate!
      authentication_token = cookies[:authentication_token]
      token_id, token = authentication_token && Database
        .where("tokens") do |x|
          x[1][0] == authentication_token &&
            Time.parse(x[1][1]) >= Time.now
        end.first

      user_id = token && token[2].to_i

      @user = User.find(user_id)

      unless @user
        redirect to("/sign_in")
      end

      token[1] = (Time.now + 600).to_s
      Database.update("tokens", token_id, token)
    end
  end

  helpers Auth
end

get "/" do
  render_with_layout("index.html")
end

get "/sign_in" do
  render_with_layout("sign_in.html")
end

post "/sign_in" do
  id, _ = Database
    .where("users") { |x| x[1][0] == params["email"] }
    .first
  user = User.find(id)

  unless user
    return render_with_layout("wrong_sign_in.html")
  end

  user.sign_in_via_password(params["password"])

  unless user.signed_in?
    return render_with_layout("wrong_sign_in.html")
  end

  token = [SecureRandom.hex + SecureRandom.hex, (Time.now + 600).to_s, user.id.to_s]
  Database.insert("tokens", token)
  Database
    .where("tokens") { |x| Time.parse(x[1][1]) < Time.now }
    .each do |row|
      id, _ = row
      Database.delete("tokens", id)
    end
  cookies[:authentication_token] = token[0]

  render_with_layout("successful_sign_in.html")
end

get "/sign_up" do
  render_with_layout("sign_up.html")
end

post "/sign_up" do
  unless params["password"] == params["confirm"]
    @validation_error = "Password confirmation and password should be same."
    return render_with_layout("sign_up.html")
  end

  exists = Database
    .where("users") { |x| x[1][0] == params["email"] }
    .any?

  if exists
    @validation_error = "User with such email already exists."
    return render_with_layout("sign_up.html")
  end

  user = User.new(email: params["email"], password: params["password"])

  render_with_layout("successful_sign_up.html")
end

get "/home" do
  authenticate!
  render_with_layout("home.html")
end

get "/users" do
  authenticate!
  @users = Database
    .where("users") { true }
    .map do |row|
      id, found = row
      User.load(id, found)
    end
  render_with_layout("users.html")
end
