require "rubygems"
require "bundler"
Bundler.require(:default, ENV["RACK_ENV"] || :development)

Dir[File.dirname(__FILE__) + '/lib/*.rb'].each {|file| require file }

class OKRClub < Sinatra::Base
  register Sinatra::ActiveRecordExtension

  # Logging
  $logger = Logger.new(STDOUT)

  # Sessions
  secret = ENV["SESSION_SECRET"] || "secret"
  $logger.warn "Session secret is not secure!" if secret.eql? "secret"
  use Rack::Session::Cookie, :expire_after => 14400, :secret => secret

  # Those popup messages
  use Rack::Flash

  # Configure Warden (Authentication)
  # Use this with env["warden"].authenticate!
  use Warden::Manager do |config|
    # serialize user to session ->
    config.serialize_into_session{|user| user.id}
    # serialize user from session <-
    config.serialize_from_session{|id| User.get(id) }
    # configuring strategies
    config.scope_defaults :default,
      strategies: [:password],
      action: "auth/unauthenticated"
    config.failure_app = self
  end

  def current_user
    User.find(user_id)
  end

  def user_id
    session["warden.user.default.key"]
  end

  configure do
    # Configure Database
    RACK_ENV = (ENV["RACK_ENV"] || :development).to_sym
    connections = {
      :development => "postgres://localhost/okrclub",
      :test => "postgres://postgres@localhost/okrclub_test",
      :production => ENV["DATABASE_URL"]
    }
    url = URI(connections[RACK_ENV])
    options = {
      :adapter => url.scheme,
      :host => url.host,
      :port => url.port,
      :database => url.path[1..-1],
      :username => url.user,
      :password => url.password
    }

    case url.scheme
    when "sqlite"
      options[:adapter] = "sqlite3"
      options[:database] = url.host + url.path
    when "postgres"
      options[:adapter] = "postgresql"
    end
    set :database, options

    Warden::Strategies.add(:password) do
      def flash
        env["x-rack.flash"]
      end

      # valid params for authentication
      def valid?
        params["user"] && params["user"]["email"] && params["user"]["password"]
      end

      # authenticating user
      def authenticate!
        # find for user
        user = User.where(email: params["user"]["email"]).first
        if user.nil?
          fail!("Invalid email, does not exists!")
        elsif user.authenticate(params["user"]["password"])
          flash[:success] = "Logged in"
          success!(user)
        else
          fail!("There are errors, please try again")
        end
      end
    end
  end

  before do
    session[:csrf] ||= SecureRandom.hex(32)

    response.set_cookie 'authenticity_token', {
      value: session[:csrf],
      expires: Time.now + (60 * 60 * 24 * 180), # 180 days
      path: '/',
      httponly: true
      # secure: true # if HTTPS then enable this
    }

    # A Rack method, that checks if we're doing anything other than GET
    if !request.safe?
      # check that the session is the same as the form
      #   parameter AND the cookie value
      if session[:csrf] == params['_csrf'] && session[:csrf] == request.cookies['authenticity_token']
        # everything is good.
      else
        flash[:error] = 'CSRF failed'
        halt 403, 'CSRF failed'
      end
    end
  end

  get "/" do
    if user_id && current_user
      redirect "/home"
    else
      erb :index
    end
  end

  get "/home" do
    if user_id && current_user
      @user = current_user
      @dates = [
        Chronic.parse("tomorrow"),
        Chronic.parse("sunday"),
        Chronic.parse("next month", guess: :begin),
        Chronic.parse("march 31st"), # EOQ1
        Chronic.parse("june 30th"), # EOQ2
        Chronic.parse("september 30th"), # EOQ3
        Chronic.parse("december 31st"), # EOQ4
      ].sort.uniq

      erb :home
    else
      redirect "/"
    end
  end

  post "/objectives" do
    o = Objective.new
    o.text = params["new_objective"]
    o.user = current_user
    o.start = Time.now
    o.end = params["duedate"]
    o.save

    redirect "/"
  end

  post "/requirements" do
    @user = current_user

    o = Objective.find(params["objective_id"])
    if o.user != @user
      halt 403, "Can not save objective for another user."
      return
    end

    r = Requirement.new
    r.text = params["new_requirement"]
    r.objective = o
    r.save

    redirect "/"
  end

  get "/login" do
    redirect "/auth/login"
  end

  get "/logout" do
    redirect "/auth/logout"
  end

  get "/signup" do
    redirect "/auth/signup"
  end

  get "/auth/signup" do
    if user_id && current_user
      redirect "/home"
    else
      erb :signup
    end
  end

  post "/auth/signup" do
    inc = params["user"]

    message = "Your passwords don't match." if inc["password"] != inc["verify_password"]
    message = "This email is already taken." if !User.where(name: inc["email"]).first.nil?

    if message
      flash[:error] = message
      redirect "/auth/signup"
      return
    end

    u = User.new
    u.password = inc["password"]
    u.email = inc["email"]
    u.name = "friend"
    u.save

    flash[:success] = "User created. Please Log in."

    redirect "/"
  end

  get "/auth/login" do
    if user_id && current_user
      redirect "/home"
    else
      erb :login
    end
  end

  post "/auth/login" do
    env["warden"].authenticate!

    if session[:return_to].nil?
      redirect "/home"
    else
      redirect session[:return_to]
    end
  end

  # Required by Warden for when user reach a protected route watched by Warden
  # calls.
  post "/auth/unauthenticated" do
    session[:return_to] = env["warden.options"][:attempted_path]
    flash[:error] = env["warden"].message  || "That didn't work. Please log in."
    redirect "/auth/login"
  end

  # Required by Warden to ensure user logout a session data removal.
  get "/auth/logout" do
    env["warden"].raw_session.inspect
    env["warden"].logout
    flash[:success] = "Successfully logged out"
    redirect "/"
  end

  get "/about" do
    erb :about
  end

  error 400..510 do
    @code = response.status
    erb :error
  end
end
