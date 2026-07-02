# encoding: utf-8

require 'openc3/models/model'
require 'openc3/utilities/store'

module OpenC3
  # 쪽지(내부 메시지) 모델 - 외부 클라이언트가 공개 API로 생성하고 관제사 봇이 열람함
  class MailboxModel < Model
    MAILBOX_TYPE = 'mailbox'.freeze
    PRIMARY_KEY  = '__MAILBOX'.freeze

    def self.pk(scope)
      "#{scope}#{PRIMARY_KEY}"
    end

    # 모든 쪽지 반환 (최신순)
    def self.all(scope:, limit: 100)
      result = Store.zrevrangebyscore(pk(scope), '+inf', '-inf', limit: [0, limit])
      result.map { |item| JSON.parse(item, allow_nan: true) }
    end

    # ID(타임스탬프)로 단일 쪽지 반환
    def self.get(id:, scope:)
      result = Store.zrangebyscore(pk(scope), id, id)
      return nil if result.empty?
      JSON.parse(result[0], allow_nan: true)
    end

    # 쪽지 삭제
    def self.destroy(id:, scope:)
      result = Store.zrangebyscore(pk(scope), id, id)
      return 0 if result.empty?
      Store.zrem(pk(scope), result[0])
    end

    attr_reader :id, :from_email, :subject, :body, :received_at

    def initialize(
      scope:,
      from_email:,
      subject:,
      body:,
      received_at: nil,
      id: nil,
      updated_at: 0,
      type: MAILBOX_TYPE
    )
      @id          = id || Time.now.to_nsec_from_epoch
      @from_email  = from_email
      @subject     = subject
      @body        = body  # HTML 그대로 저장 (필터 없음)
      @received_at = received_at || Time.now.to_i
      @type        = type
      super(self.class.pk(scope), name: "mailbox_#{@id}", scope: scope, updated_at: updated_at)
    end

    def create
      @updated_at = Time.now.to_nsec_from_epoch
      Store.zadd(self.class.pk(@scope), @id, JSON.generate(as_json, allow_nan: true))
    end

    def as_json(*a)
      {
        'id'          => @id,
        'scope'       => @scope,
        'from_email'  => @from_email,
        'subject'     => @subject,
        'body'        => @body,
        'received_at' => @received_at,
        'type'        => MAILBOX_TYPE,
        'updated_at'  => @updated_at,
      }
    end
    alias to_s as_json
  end
end
