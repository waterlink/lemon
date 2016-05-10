require "sinatra"
require "erb"

require "./lemon"

get "/" do
  render(:erb, File.read("./index.html.erb"))
end

get "/sign_in" do
  render(:erb, File.read("./sign_in.html.erb"))
end

post "/sign_in" do
  id, _ = Database
    .where("users") { |x| x[1][0] == params["email"] }
    .first
  user = User.find(id)

  unless user
    return render(:erb, File.read("./wrong_sign_in.html.erb"))
  end

  user.sign_in_via_password(params["password"])

  unless user.signed_in?
    return render(:erb, File.read("./wrong_sign_in.html.erb"))
  end

  render(:erb, File.read("./successful_sign_in.html.erb"))
end

get "/sign_up" do
  render(:erb, File.read("./sign_up.html.erb"))
end

post "/sign_up" do
  unless params["password"] == params["confirm"]
    @validation_error = "Password confirmation and password should be same."
    return render(:erb, File.read("./sign_up.html.erb"))
  end

  exists = Database
    .where("users") { |x| x[1][0] == params["email"] }
    .any?

  if exists
    @validation_error = "User with such email already exists."
    return render(:erb, File.read("./sign_up.html.erb"))
  end

  User.new(email: params["email"], password: params["password"])
  render(:erb, File.read("./successful_sign_up.html.erb"))
end
