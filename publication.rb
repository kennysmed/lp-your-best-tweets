require 'json'
require 'oauth'
require 'redis'
require 'sinatra'
require 'twitter'

# So we can see what's going wrong on Heroku.
set :show_exceptions, true

enable :sessions

# TODO: Error checking if these aren't present.
oauth = OAuth::Consumer.new(
                  ENV['TWITTER_CONSUMER_KEY'], ENV['TWITTER_CONSUMER_SECRET'],
                  { :site => 'https://api.twitter.com' })

# For fetching data from Twitter, not for doing authentication.
Twitter.configure do |config|
  config.consumer_key = ENV['TWITTER_CONSUMER_KEY'] 
  config.consumer_secret = ENV['TWITTER_CONSUMER_SECRET']
end


configure do
  uri = URI.parse(ENV['REDISCLOUD_URL'])
  REDIS = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
end


get '/edition/' do
  if params[:access_token]
    user_id = params[:access_token]
    access_token = REDIS.get("user:#{user_id}:token")
    access_token_secret = REDIS.get("user:#{user_id}:secret")

    client = Twitter::Client.new(
      :oauth_token => access_token,
      :oauth_token_secret => access_token_secret
    )

    begin
      timeline = client.user_timeline(user_id,
                                     :count => 200,
                                     :exclude_replies => false,
                                     :trim_user => true,
                                     :include_rts => false)
    rescue Twitter::Error::NotFound
      return 500, "Twitter user ID not found."
    rescue Twitter::Error::Unauthorized
      return 401, "Not authorised to access this user's timeline."
    end

    def make_score(favorite_count, retweet_count)
      return favorite_count + retweet_count
    end

    @tweets = []
    timeline.each do |tweet|
      @tweets.push({
        :text => tweet[:text],
        :favorite_count => tweet[:favorite_count],
        :retweet_count => tweet[:retweet_count],
        :score => make_score(tweet[:favorite_count], tweet[:retweet_count])
      })
    end

    @tweets.sort_by! { |k| k['score']}.reverse
    erb :my_best_tweets
  else
    return 500, 'No access token provided'
  end
end


# After clicking the link on the Publication listing on BERG Cloud Remote, the
# user arrives here to authenticate with twitter.
#
# See https://dev.twitter.com/docs/auth/implementing-sign-twitter for the
# process.
#
# == Parameters
#   params['return_url'] will be the publication-specific URL we return the
#     user to after authenticating.
#
get '/configure/' do
  if !params['return_url']
    return 400, 'No return_url parameter was provided'
  else
    # Save the return URL so we still have it after authentication.
    session[:bergcloud_return_url] = params['return_url']
  end

  # OAUTH Step 1: Obtaining a request token.
  # TODO: The publication URL shouldn't be hard-coded.
  begin
    request_token = oauth.get_request_token(
          :oauth_callback => 'http://lp-my-best-tweets.herokuapp.com/return/')
  rescue OAuth::Unauthorized
    return 401, 'Unauthorized when asking Twitter for a token to make a request' 
  end

  if request_token.callback_confirmed?
    # It's worked so far. Save these for later.
    session[:request_token] = request_token.token
    session[:request_token_secret] = request_token.secret

    # OAUTH Step 2: Redirecting the user.
    # The user is sent to Twitter and asked to approve the publication's
    # access.
    redirect request_token.authorize_url
  else
    return 400, 'Callback was not confirmed by Twitter'
  end
end


# User has returned from authenticating at Twitter.
# We now need to complete the OAuth dance, getting an access_token and secret
# for the user, which we'll store, before passing the user's Twitter ID back
# to BERG Cloud.
#
# == Parameters
#   params[:oauth_verifier] is returned from Twitter if things went well.
#
# == Session
#   These should be set in the session:
#     * :bergcloud_return_url
#     * :request_token
#     * :request_token_secret
#
get '/return/' do
  if !params[:oauth_verifier]
    return 500, 'No oauth verifier was returned by Twitter'
  else
    if !session[:bergcloud_return_url]
      return 500, 'A cookie was expected, but was missing. Are cookies enabled? Please return to BERG Cloud and try again.'
    else 
      return_url = session[:bergcloud_return_url]
      session[:bergcloud_return_url] = nil
    end

    # Recreate the request token using our stored token and secret.
    begin
      request_token = OAuth::RequestToken.new(oauth,
                                              session[:request_token],
                                              session[:request_token_secret])
    rescue OAuth::Unauthorized
      return 401, 'Unauthorized when trying to get a request token from Twitter' 
    end

    # Tidy up, now we've finished with them.
    session[:request_token] = session[:request_token_secret] = nil

    # OAuth Step 3: Converting the request token to an access token.
    begin
      # accesss_token will have access_token.token and access_token.secret
      access_token = request_token.get_access_token(
                                   :oauth_verifier => params[:oauth_verifier])
    rescue OAuth::Unauthorized
      return 401, 'Unauthorized when trying to get an access token from Twitter' 
    end

    if !access_token
      return 500, 'Unable to retrieve an access token from Twitter'
    else
      # We've finished authenticating!
      # We now need to fetch the user's ID from twitter.
      # This will give us client.current_user which contains the user's data.
      client = Twitter::Client.new(
        :oauth_token => access_token.token,
        :oauth_token_secret => access_token.secret
      )

      # We use the Twitter's User ID as the key for the data we store.
      begin
        user_id = client.current_user[:id]
      rescue Twitter::Error::BadRequest
        return 500, "Bad authentication data when trying to get user's Twitter info"
      end

      REDIS.set("user:#{user_id}:token", access_token.token)
      REDIS.set("user:#{user_id}:secret", access_token.secret)

      # If this worked, send the user's Twitter ID back to BERG Cloud
      redirect "#{return_url}?config[access_token]=#{user_id}"
    end
  end
end


# Returns a sample of the publication. Triggered by the user hitting
# 'print sample' on the publication's page on BERG Cloud.
#
# == Parameters:
#   None.
#
# == Returns:
# HTML/CSS edition with etag.
#
get '/sample/' do
  etag Digest::MD5.hexdigest('sample')
  @test_var = REDIS.get('user:12552:token')
  erb :my_best_tweets
end


post '/validate_config/' do

end

