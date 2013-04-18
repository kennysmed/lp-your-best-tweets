# coding: utf-8
require 'json'
require 'oauth'
require 'redis'
require 'sinatra'
require 'twitter'

# So we can see what's going wrong on Heroku.
set :show_exceptions, true

# Enable trim mode in templates, so we can choose to ignore blank lines by
# ending tags with -%>
set :erb, :trim => '-'

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
  # TODO make this envrinoment-specific stuff better.
  begin
    uri = URI.parse(ENV['REDISCLOUD_URL'])
    REDIS = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
  rescue URI::InvalidURIError
    REDIS = Redis.new()
  end

  # How many days' worth of tweets do we fetch?
  set :days_to_fetch, 1

  # When is the oldest tweet we'd fetch.
  set :time_cutoff, (Time.now - (86400 * settings.days_to_fetch))

  # Do we show the top 3? 10? etc.
  set :max_tweets_to_show, 3
end


helpers do
  # So we know where to do redirects to.
  # Example return: 'http://my-best-tweets.herokuapp.com'
  # Should handle http/https and port numbers.
  def domain
    protocol = request.secure? ? 'https' : 'http'
    port = request.env['SERVER_PORT'] ? ":#{request.env['SERVER_PORT']}" : ''
    return "#{protocol}://#{request.env['SERVER_NAME']}#{port}"
  end

  # Assuming we've already configured Twitter, this returns the client.
  # Pass in the user's access token and secret
  # (or the app's access token and secret).
  def twitter_client(access_token, access_token_secret)
    return Twitter::Client.new(
        :oauth_token => access_token,
        :oauth_token_secret => access_token_secret
      )
  end

  # Returns a score for a tweet based on number of favorites and retweets.
  def tweet_score(favorite_count, retweet_count)
    return favorite_count + (retweet_count * 2)
  end
end


# Display the publication for a user.
# 
# == Parameters
#   params[:access_token] should be a the access_token received from Twitter
#     when the user authenticated.
#
get '/edition/' do
  if !params[:access_token]
    return 500, 'No access token provided.'
  end

  access_token = params[:access_token]
  access_token_secret = REDIS.get("user:#{access_token}:secret")
  user_id = REDIS.get("user:#{access_token}:user_id").to_i
  client = twitter_client(access_token, access_token_secret)

  begin
    # TODO: We're assuming that the period of tweets we need to fetch will be
    # within the 200-per-request limit. But it might not be...
    timeline = client.user_timeline(user_id,
                                   :count => 200,
                                   :exclude_replies => false,
                                   :trim_user => false, 
                                   :include_rts => false)
  rescue Twitter::Error::Unauthorized
    return 401, "Not authorised to access this user's timeline."
  rescue Twitter::Error::NotFound
    return 500, "Twitter user ID not found."
  rescue Twitter::Error
    return 500, "There was an error when fetching the timeline."
  end

  # Now we've got loads of tweets we want to make a list of the ones from
  # the past n days, and calculate their favorite/retweet score.
  time_cutoff = (Time.now - (86400 * settings.days_to_fetch))
  @tweets = []
  timeline.each do |t|
    break if t.created_at < time_cutoff
    @tweets.push({
      :text => t[:text],
      :created_at => t[:created_at],
      :favorite_count => t[:favorite_count],
      :retweet_count => t[:retweet_count],
      :score => tweet_score(t[:favorite_count], t[:retweet_count])
    })
  end
  # The total tweets sent by this user in that time period.
  @total_tweets = @tweets.length

  # Get rid of any with no favorites or retweets.
  @tweets.reject! { |t| t[:score] == 0 }

  if @tweets.length == 0
    return 200, "No tweets to display for this day"
  end

  # Into reverse order by score:
  @tweets.sort! { |x, y| y[:score] <=> x[:score] }

  # The variables needed for the template:
  @tweets = @tweets[0...settings.max_tweets_to_show]
  @days_to_fetch = settings.days_to_fetch
  # These can change, so we don't store them in Redis, but get them from the
  # fetched tweets.
  @screen_name = timeline[0][:user][:screen_name]
  @user_name = timeline[0][:user][:name]
  @profile_image_url = timeline[0][:user][:profile_image_url]
  @domain = domain

  # Set the etag to be for this Twitter user today.
  etag Digest::MD5.hexdigest(@screen_name + Date.today.strftime('%d%m%Y'))

  # Let's go!
  erb :my_best_tweets
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
  end

  # Save the return URL so we still have it after authentication.
  session[:bergcloud_return_url] = params['return_url']

  # OAUTH Step 1: Obtaining a request token.
  # (`domain` is in `helpers`)
  begin
    request_token = oauth.get_request_token(
                                        :oauth_callback => "#{domain}/return/")
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
  if params[:denied]
    # TODO: We should return to Remote somehow...?
    return 500, "User chose not to authorise with Twitter."
  end

  if !params[:oauth_verifier]
    return 500, 'No oauth verifier was returned by Twitter'
  end

  if !session[:bergcloud_return_url]
    return 500, 'A cookie was expected, but was missing. Are cookies enabled? Please return to BERG Cloud and try again.'
  end

  return_url = session[:bergcloud_return_url]
  session[:bergcloud_return_url] = nil

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
  end

  # We've finished authenticating!
  # We now need to fetch the user's ID from twitter.
  # The client will enable us to access client.current_user which contains
  # the user's data.
  client = twitter_client(access_token.token, access_token.secret)

  # Although we have the access token and secret, we still need the Twitter
  # user ID in order to actually fetch the tweets for the publication.
  begin
    user_id = client.current_user[:id]
  rescue Twitter::Error::BadRequest
    return 500, "Bad authentication data when trying to get user's Twitter info"
  end

  REDIS.set("user:#{access_token.token}:user_id", user_id)
  REDIS.set("user:#{access_token.token}:secret", access_token.secret)

  # If this worked, send the user's Access Token back to BERG Cloud
  redirect "#{return_url}?config[access_token]=#{access_token.token}"
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
  # Some hard-coded tweets from a single day of @samuelpepys' tweets.
  @tweets = [
    # https://twitter.com/samuelpepys/status/323368562943197184
    {:text => "Drank a good morning draught with Mr. Sheply, which occasioned my thinking upon the happy life that I live now.",
      :created_at => Time.new(2013, 4, 14, 10, 34, 07, '+01:00'),
      :favorite_count => 11, :retweet_count => 40, :score => tweet_score(11, 40)},
    # https://twitter.com/samuelpepys/status/323358544365756417
    {:text => "What with the goodness of the bed and the rocking of the ship I slept till almost ten o’clock.",
      :created_at => Time.new(2013, 4, 14, 9, 54, 19, '+01:00'),
      :favorite_count => 9, :retweet_count => 25, :score => tweet_score(9, 25)},
    # https://twitter.com/samuelpepys/status/323237710284353537
    {:text => "It being very rainy, and the rain coming upon my bed, I went and lay with John Goods in the great cabin below.",
      :created_at => Time.new(2013, 4, 14, 1, 54, 10, '+01:00'),
      :favorite_count => 1, :retweet_count => 15, :score => tweet_score(1, 15)},
  ]
  # Into reverse order by score:
  @tweets.sort! { |x, y| y[:score] <=> x[:score] }

  # The variables needed for the template:
  @total_tweets = 8
  @tweets = @tweets[0...settings.max_tweets_to_show]
  @days_to_fetch = 1
  @screen_name = 'samuelpepys'
  @user_name = 'Samuel Pepys'
  @profile_image_url = domain + '/sample_avatar.jpg'
  @domain = domain

  etag Digest::MD5.hexdigest('sample')

  # Let's go!
  erb :my_best_tweets
end


post '/validate_config/' do

end

