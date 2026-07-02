# encoding: utf-8

require '/openc3/lib/openc3/models/mailbox_model'

# 쪽지 컨트롤러
# - index / show / destroy: 관제사 인증 필요 (system 권한)
# - create: 인증 없음 (내부 이메일 포워딩 데몬 전용)
class MailboxController < ApplicationController
  NOT_FOUND = 'not found'.freeze

  before_action { @model_class = OpenC3::MailboxModel }

  # GET /mailbox?scope=DEFAULT
  # 쪽지 목록 반환 (최신순) - 인증 없이 접근 가능
  def index
    action do
      messages = @model_class.all(scope: params[:scope])
      render json: messages
    end
  end

  # GET /mailbox/:id?scope=DEFAULT
  def show
    action do
      msg = @model_class.get(id: params[:id].to_i, scope: params[:scope])
      if msg
        render json: msg
      else
        render json: { status: 'error', message: NOT_FOUND }, status: 404
      end
    end
  end

  # POST /mailbox?scope=DEFAULT
  # 인증 없이 접근 가능 - 내부 이메일 포워딩 데몬이 사용
  # body 파라미터는 HTML 그대로 저장 (XSS 필터 없음)
  def create
    action do
      hash = params.to_unsafe_h.slice(:from_email, :subject, :body).to_h
      raise ArgumentError, "from_email is required" if hash['from_email'].nil?
      raise ArgumentError, "subject is required"    if hash['subject'].nil?
      raise ArgumentError, "body is required"       if hash['body'].nil?

      model = @model_class.new(
        scope:      params[:scope] || 'DEFAULT',
        from_email: hash['from_email'],
        subject:    hash['subject'],
        body:       hash['body'],
      )
      model.create
      render json: model.as_json(), status: 201
    end
  end

  # DELETE /mailbox/:id?scope=DEFAULT
  def destroy
    return unless authorization('system')
    action do
      count = @model_class.destroy(id: params[:id].to_i, scope: params[:scope])
      if count == 0
        render json: { status: 'error', message: NOT_FOUND }, status: 404
      else
        render json: { status: count }
      end
    end
  end

  private

  def action
    yield
  rescue ArgumentError, TypeError => e
    render json: { status: 'error', message: "Invalid input: #{e.message}" }, status: 400
  rescue StandardError => e
    render json: { status: 'error', message: e.message, backtrace: e.backtrace }, status: 500
  end
end
