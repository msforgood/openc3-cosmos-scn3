# encoding: utf-8

require 'openc3/models/model'
require 'openc3/utilities/store'

module OpenC3
  # KFWS-1 위성의 FLAME_APP(산불 감시 열화상 카메라) 상태를 지상국 쪽에서
  # 흉내낸 모델. 실제 위성 텔레메트리 대신 Redis에 ImagerActive/EvidenceSample을
  # 들고 있다가, DISABLE_IMAGER 명령이 오면 fire_evidence.dat(=flag)을 읽어
  # EvidenceSample에 적재한다. HK 조회(SEND_HK에 해당)로만 그 값을 꺼내볼 수 있다.
  class FlameAppModel < Model
    PRIMARY_KEY   = '__FLAME_APP'.freeze
    EVIDENCE_FILE = '/flag.txt'.freeze # 시뮬레이션 상 /cf/fire_evidence.dat에 해당

    def self.pk(scope)
      "#{scope}#{PRIMARY_KEY}"
    end

    # 최초 상태: 카메라 켜짐, 증거 없음 (산불 은닉 이전)
    def self.hk(scope:)
      hash = Store.hgetall(pk(scope))
      return default_hk if hash.nil? || hash.empty?
      {
        'imager_active'      => hash['imager_active'] == 'true',
        'active_alarm_zones' => hash['imager_active'] == 'true' ? 1 : 0,
        'evidence_sample'    => hash['evidence_sample'],
      }
    end

    def self.default_hk
      { 'imager_active' => true, 'active_alarm_zones' => 1, 'evidence_sample' => nil }
    end

    # FLAME_APP_DISABLE_IMAGER_CC 에 해당하는 정상 운용 명령.
    # 카메라를 끄면 그 부작용으로 은닉 감지 로직이 fire_evidence.dat을 읽어
    # EvidenceSample에 적재한다 (관제사가 정상적으로 SEND_HK 하기 전까지는 아무도 못 봄).
    def self.disable_imager!(scope:)
      evidence = File.read(EVIDENCE_FILE).strip
      Store.hset(pk(scope), 'imager_active', 'false')
      Store.hset(pk(scope), 'evidence_sample', evidence)
      evidence
    end

    def self.enable_imager!(scope:)
      Store.hset(pk(scope), 'imager_active', 'true')
      Store.hdel(pk(scope), 'evidence_sample')
    end
  end
end
