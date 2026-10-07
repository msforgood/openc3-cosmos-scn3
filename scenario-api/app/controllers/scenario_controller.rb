class ScenarioController < ActionController::API
  before_action :check_body
  rescue_from StandardError, with: :internal_error
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: :invalid_json
  rescue_from Scenario::Error, with: :domain_error

  def health
    raise Scenario::Error.new('reconciler_unavailable', nil, 503) unless Scenario::Runtime.healthy?
    render json: { status: 'ok', component: 'scenario-api', contract_version: 1 }
  end

  def scenarios
    render json: { items: service.scenarios(scope: scope, token: token) }
  end

  def scenario
    render json: service.scenario(params[:id], scope: scope, target: params[:target], token: token)
  end

  def create
    result, code = service.create(body.merge('scope' => scope), token: token, request_key: request.headers['Idempotency-Key'])
    render json: result, status: code
  end

  def runs
    render json: { items: service.list(scope: scope, target: params[:target], token: token, limit: params[:limit] || 25) }
  end

  def reconcile
    render json: service.reconcile_request(body.merge('scope' => scope), token: token, request_key: request.headers['Idempotency-Key'])
  end

  def show
    render json: service.get(params[:id], scope: scope, token: token)
  end

  def events
    render json: service.events(params[:id], scope: scope, token: token, after: params[:after] || 0, limit: params[:limit] || 100)
  end

  def context
    render json: service.context(params[:id], scope: scope, token: token)
  end

  def stop
    strict_fields!(%w[scope])
    render json: service.stop(params[:id], scope: scope, token: token)
  end

  def prompt
    strict_fields!(%w[scope prompt_id answer])
    render json: service.answer(params[:id], scope: scope, token: token, prompt_id: body['prompt_id'], answer: body['answer'])
  end

  def callback
    render json: service.callback(params[:id], scope: scope, token: token, payload: body)
  end

  private

  def service
    Scenario::Runtime.service
  end

  def token
    request.headers['Authorization']
  end

  def scope
    query = request.query_parameters['scope']
    supplied = request.post? ? body['scope'] : nil
    raise Scenario::Error.new('scope_mismatch') if query && supplied && query != supplied
    supplied || query
  end

  def body
    @body ||= begin
      raw = request.body.read(16_385)
      raise Scenario::Error.new('body_too_large', nil, 413) if raw.bytesize > 16_384
      parsed = JSON.parse(raw.empty? ? '{}' : raw)
      raise Scenario::Error.new('invalid_json') unless parsed.is_a?(Hash)
      parsed
    rescue JSON::ParserError
      raise Scenario::Error.new('invalid_json')
    end
  end

  def check_body
    raise Scenario::Error.new('body_too_large', nil, 413) if request.content_length.to_i > 16_384
    if request.post?
      raise Scenario::Error.new('json_required', nil, 415) unless request.media_type == 'application/json'
      body
    end
  end

  def strict_fields!(fields)
    raise Scenario::Error.new('unexpected_fields') unless (body.keys - fields).empty?
  end

  def domain_error(error)
    render json: { error: { code: error.code, message: error.message } }, status: error.status
  end

  def invalid_json(_error)
    domain_error(Scenario::Error.new('invalid_json'))
  end

  def internal_error(_error)
    # Do not log exception messages: upstream libraries may include bearer tokens or URLs.
    domain_error(Scenario::Error.new('service_unavailable', nil, 503))
  end
end
