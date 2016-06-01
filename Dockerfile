FROM ruby:2.3.1

ADD usage.rb /code/usage.rb
ADD Gemfile /code/Gemfile
ADD start.sh /start.sh
RUN cd /code && bundle install

ENTRYPOINT ["/start.sh"]
