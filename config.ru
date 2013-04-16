# Enable real-time logging on Heroku.
$stdout.sync = true

require './publication'
run Sinatra::Application