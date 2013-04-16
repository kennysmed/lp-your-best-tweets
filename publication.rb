require 'oauth'
require 'sinatra'
require 'twitter'

# So we can see what's going wrong on Heroku.
set :show_exceptions, true

enable :sessions

# TODO: Error checking if these aren't present.
oauth = OAuth::Consumer.new(
                  ENV['TWITTER_CONSUMER_KEY'], ENV['TWITTER_CONSUMER_SECRET'],
                  { :site => 'https://api.twitter.com' })


# TODO
get '/edition/' do
  if params[:access_token]
    access_token = params[:access_token]
    erb :my_best_tweets
  else
    return 500, 'No access token provided'
  end
end


# After clicking the link on the Publication listing on BERG Cloud Remote, the
# user arrives here to authenticate with twitter.
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

  # Send the user to Twitter to authorise, ask Twitter to return to /return/.
  # TODO: The publication URL shouldn't be hard-coded.
  begin
    request_token = oauth.get_request_token(
          :oauth_callback => 'http://lp-my-best-tweets.herokuapp.com/return/')
  rescue OAuth::Unauthorized
    return 401, 'Unauthorized when asking Twitter for a token to make a request' 
  end

  if request_token.callback_confirmed?
    # Everything's worked! Save these for later.
    session[:request_token] = request_token.token
    session[:request_token_secret] = request_token.secret

    redirect request_token.authorize_url
  else
    return 400, 'Callback was not confirmed by Twitter'
  end
end


# User has returned from authenticating at Twitter.
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

    begin
      request_token = OAuth::RequestToken.new(oauth,
                                              session[:request_token],
                                              session[:request_token_secret])
    rescue OAuth::Unauthorized
      return 401, 'Unauthorized when trying to get a request token from Twitter' 
    end

    # Tidy up, now we've used them.
    session[:request_token] = session[:request_token_secret] = nil

    begin 
      # accesss_token will have access_token.token and access_token.secret
      access_token = request_token.get_access_token(
                                   :oauth_verifier => params[:oauth_verifier])
    rescue OAuth::Unauthorized
      return 401, 'Unauthorized when trying to get an access token from Twitter' 
    end

    if access_token
      # If this worked, send the access token back to BERG Cloud
      redirect "#{return_url}?config[access_token]=#{access_token.token}"
    else
      return 500, 'Unable to retrieve an access token from Twitter'
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
  @access_token = "TEST_ACCESS_TOKEN"
  erb :my_best_tweets
end


post '/validate_config/' do

end

