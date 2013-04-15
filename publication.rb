require 'oauth/consumer'
require 'sinatra'
require 'twitter'


get '/edition/' do

end


# https://dev.twitter.com/docs/auth/implementing-sign-twitter
# http://michaelhallsmoore.com/blog/Getting-to-grips-with-the-Ruby-OAuth-gem-and-the-Twitter-API
get '/configure/' do
  # First, set a cookie so we know where to return the token to when it's
  # returned by Twitter.
  # BERG Cloud will pass us a return_url which is specific to our publication
  # within BERG Cloud
  if params['return_url']
    response.set_cookie(
      'bergcloud_return_url',
      :value => params['return_url'],
      :domain => request.host,
      :path => '/',
      :expires => Time.now + 86400) # Validity of one day
  else
    # Should never happen
    return 400, 'No return_url parameter was provided'
  end

  # Send the user to Twitter to authorise, ask Twitter to return to /return/.

end


get '/return/' do

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
  erb :my_best_tweets
end


# post '/validate_config/' do

# end
