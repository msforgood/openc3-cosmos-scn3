port ENV.fetch('PORT', '2910')
threads 2, 8
workers 0
environment ENV.fetch('RAILS_ENV', 'production')
worker_timeout 30
