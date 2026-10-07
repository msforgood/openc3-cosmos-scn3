ARG OPENC3_BASE_IMAGE=openc3inc/openc3-cosmos-script-runner-api:6.10.1
FROM ${OPENC3_BASE_IMAGE}
ARG SCENARIO_VERSION=1.0.11
USER root
WORKDIR /scenario-api
RUN apk add --no-cache sqlite-libs sqlite-dev build-base
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without '' && bundle config set --local frozen true && bundle install --jobs 4 --retry 2
COPY --chown=1001:1001 . .
# Both images consume the procedure package as their catalog authority.
COPY --from=scenario_catalog --chown=1001:1001 lib/scenarios.json lib/safety_policy.json ./config/
COPY --from=scenario_catalog --chown=1001:1001 procedures/run_scenario.py ./config/
ENV SCENARIO_VERSION=${SCENARIO_VERSION}
RUN mkdir -p /data /scenario-api/tmp /scenario-api/log && chown -R 1001:1001 /data /scenario-api/tmp /scenario-api/log
ENV RAILS_ENV=production PORT=2910 SCENARIO_DB=/data/scenario.sqlite3
USER 1001:1001
EXPOSE 2910
HEALTHCHECK --interval=15s --timeout=3s --start-period=15s --retries=3 CMD ruby -rnet/http -e 'exit(Net::HTTP.get_response(URI("http://127.0.0.1:2910/scenario-api/health")).code == "200" ? 0 : 1)'
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
