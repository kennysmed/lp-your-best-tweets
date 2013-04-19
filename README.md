
# Your Best Tweets - A Little Printer publication

Displays the most popular Tweets, as measured by Retweets and Favorites, from the past 24 hours, as a [Little Printer](http://bergcloud.com/littleprinter/) publication.

This publication is a Ruby app using Sinatra, and requires Redis. It has only been run in production on [Heroku](http://heroku.com/) using the [Redis Cloud](https://addons.heroku.com/rediscloud) add-on.


## Setting up

Assuming you're familiar with the [guide to creating a publication](http://remote.bergcloud.com/developers/reference)...

1. Set the environment variable `RACK_ENV` to either `production` or `development`.

2. If the environment is `production` we require the `REDISCLOUD_URL` environment variable to be set. If `development`, we assume an open, local Redis.

3. Create a read-only Twitter App at https://dev.twitter.com/apps

4. Set the Twitter app's Callback URL to be http://your-app-name.herokuapp.com/return/ or http://localhost:5000/return/ etc, depending on where the publication is hosted.

5. Set the Twitter app's Consumer Key and Consumer Secret as the environment variables `TWITTER_CONSUMER_KEY` and `TWITTER_CONSUMER_SECRET`.

So, your four environment variables in production will be:

    RACK_ENV
    REDISCLOUD_URL
    TWITTER_CONSUMER_KEY
    TWITTER_CONSUMER_SECRET

In development, it's the same except `REDISCLOUD_URL` isn't used.

