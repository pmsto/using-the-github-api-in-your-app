require 'sinatra'
require 'octokit'
require 'json'
require 'openssl' # Used to verify the webhook signature
require 'jwt'     # Used to authenticate a GitHub App
require 'time'    # Used to get ISO 8601 representation of a Time object
require 'logger'

set :port, 3000


# This is template code to create a GitHub App server.
# You can read more about GitHub Apps here: # https://developer.github.com/apps/
#
# On its own, this app does absolutely nothing, except that it can be installed.
# It's up to you to add fun functionality!
# You can check out one example in advanced_server.rb.
#
# This code is a Sinatra app, for two reasons:
#   1. Because the app will require a landing page for installation.
#   2. To easily handle webhook events.
#
#
# Of course, not all apps need to receive and process events!
# Feel free to rip out the event handling code if you don't need it.
#
# Have fun!
#

class GHAapp < Sinatra::Application

  # !!! DO NOT EVER USE HARD-CODED VALUES IN A REAL APP !!!
  # Instead, set and read app tokens or other secrets in your code
  # in a runtime source, like an environment variable like below

  # Expects that the private key has been set as an environment variable in
  # PEM format using the following command to replace newlines with the
  # literal `\n`:
  #   export GITHUB_PRIVATE_KEY=`awk '{printf "%s\\n", $0}' private-key.pem`
  #
  # Converts the newlines
  PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n"))

  # Your registered app must have a secret set. The secret is used to verify
  # that webhooks are sent by GitHub.
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']

  # The GitHub App's identifier (type integer) set when registering an app.
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']

  # Turn on Sinatra's verbose logging during development
  configure :development do
    set :logging, Logger::DEBUG
  end


  # Before each request to the `/event_handler` route
  before '/event_handler' do
    get_payload_request(request)
    verify_webhook_signature
    authenticate_app
    # Authenticate each installation of the app in order to run API operations
    authenticate_installation(@payload)
  end


  post '/event_handler' do

    case request.env['HTTP_X_GITHUB_EVENT']
    when 'issues'
      if @payload['action'] === 'opened'
        handle_issue_opened_event(@payload)
      end
    end

    'ok'  # we have to return _something_ ;)

  end


  helpers do

    # When an issue is opened, add a label
    def handle_issue_opened_event(payload)
      repo = payload['repository']['full_name']
      issue_number = payload['issue']['number']
      @installation_client.add_labels_to_an_issue(repo, issue_number, ['needs-response'])
    end

    # Saves the raw payload and converts the payload to JSON format
    def get_payload_request(request)
      # request.body is an IO or StringIO object
      # Rewind in case someone already read it
      request.body.rewind
      # The raw text of the body is required for webhook signature verification
      @payload_raw = request.body.read
      begin
        @payload = JSON.parse @payload_raw
      rescue => e
        fail  "Invalid JSON (#{e}): #{@payload_raw}"
      end
    end

    # Instantiate an Octokit client authenticated as a GitHub App.
    # GitHub App authentication equires that we construct a
    # JWT (https://jwt.io/introduction/) signed with the app's private key,
    # so GitHub can be sure that it came from the app an not altererd by
    # a malicious third party.
    def authenticate_app
      payload = {
          # The time that this JWT was issued, _i.e._ now.
          iat: Time.now.to_i,

          # JWT expiration time (10 minute maximum)
          exp: Time.now.to_i + (10 * 60),

          # Your GitHub App's identifier number
          iss: APP_IDENTIFIER
      }

      # Cryptographically sign the JWT
      jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')

      # Create the Octokit client, using the JWT as the auth token.
      @app_client ||= Octokit::Client.new(bearer_token: jwt)
    end

    # Instantiate an Octokit client authenticated as an installation of a
    # GitHub App to run API operations.
    def authenticate_installation(payload)
      installation_id = payload['installation']['id']
      installation_token = @app_client.create_app_installation_access_token(installation_id)[:token]
      @installation_client = Octokit::Client.new(bearer_token: installation_token)
    end

    # Check X-Hub-Signature to confirm that this webhook was generated by
    # GitHub, and not a malicious third party.
    #
    # GitHub will the WEBHOOK_SECRET, registered
    # to the GitHub App, to create a hash signature sent in each webhook payload
    # in the `X-HUB-Signature` header. This code computes the expected hash
    # signature and compares it to the signature sent in the `X-HUB-Signature`
    # header. If they don't match, this request is an attack, and we should
    # reject it. GitHub uses the HMAC hexdigest to compute the signature. The
    # `X-HUB-Signature` looks something like this: "sha1=123456"
    # See https://developer.github.com/webhooks/securing/ for details
    def verify_webhook_signature
      their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
      method, their_digest = their_signature_header.split('=')
      our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, @payload_raw)
      halt 401 unless their_digest == our_digest

      # The X-GITHUB-EVENT header provides the name of the event.
      # The action value indicates the which action triggered the event.
      logger.debug "---- recevied event #{request.env['HTTP_X_GITHUB_EVENT']}"
      logger.debug "----    action #{@payload['action']}" unless @payload['action'].nil?
    end

  end


  # Finally some logic to let us run this server directly from the commandline, or with Rack
  # Don't worry too much about this code ;) But, for the curious:
  # $0 is the executed file
  # __FILE__ is the current file
  # If they are the same—that is, we are running this file directly, call the Sinatra run method
  run! if __FILE__ == $0
end
