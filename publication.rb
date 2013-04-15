require 'oauth'
require 'sinatra'
require 'twitter'

# TODO: Error checking if these aren't present.
set :twitter_consumer_key, ENV['TWITTER_CONSUMER_KEY']
set :twitter_consumer_secret, ENV['TWITTER_CONSUMER_SECRET']

oauth = OAuth::Consumer.new(:twitter_consumer_key, :twitter_consumer_secret,
                                        { :site => 'https://api.twitter.com' })


get '/edition/' do
  if params[:access_token]
    access_token = params[:access_token]
    erb :my_best_tweets
  else
    return 500, 'No access token provided'
  end

end


get '/configure/' do
  # First, set a cookie so we know where to return the token to when it's
  # returned by Twitter.
  # BERG Cloud will pass us a return_url which is specific to our publication
  # within BERG Cloud
  if params['return_url']
    response.set_cookie('bergcloud_return_url',
      :value => params['return_url'],
      :domain => request.host,
      :path => '/',
      :expires => Time.now + 86400) # Validity of one day
  else
    # Should never happen
    return 400, 'No return_url parameter was provided'
  end

  # Send the user to Twitter to authorise, ask Twitter to return to /return/.
  # TODO: The URL shouldn't be hard-coded.
  begin
    request_token = oauth.get_request_token(
          :oauth_callback => 'http://lp-my-best-tweets.herokuapp.com/return/')
  rescue OAuth::Unauthorized
    return 400, 'Unauthorized when trying to get a request token from Twitter' 
  end

  # TODO:
  # * Check that oauth_callback_confirmed is true.

  session[:token] = request_token.token
  session[:secret] = request_token.secret

  redirect_to request_token.authorize_url
end


get '/return/' do
  # User has returned from Twitter.

  if params[:oauth_verifier]
    if request.cookies['bergcloud_return_url'].nil?
      return 500, 'A cookie was expected, but was missing. Are cookies enabled? Please return to BERG Cloud and try again.'
    else 
      return_url = request.cookies['bergcloud_return_url']
    end

    request_token = OAuth::RequestToken.new(oauth, session[:request_token],
                                                  session[:request_token_secret])
    access_token = request_token.get_access_token(
                                     :oauth_verifier => params[:oauth_verifier])

    if access_token
      # If this worked, send the access token back to BERG Cloud
      redirect "#{return_url}?config[access_token]=#{access_token}"
    else
      return 500, 'Unable to retrieve an access token from Instagram'
    end
  else
    return 500, 'No oauth verifier was returned by Twitter'
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
  @access_token = "TEST_ACCESS_TOKEN"
  erb :my_best_tweets
end


post '/validate_config/' do

end
