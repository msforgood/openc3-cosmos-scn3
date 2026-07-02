# encoding: utf-8

require '/openc3/lib/openc3/models/flame_app_model'

# KFWS-1 위성 FLAME_APP의 HK(하우스키핑) 텔레메트리 조회.
# 실제 위성이었다면 SEND_HK 명령 후 UDP로 내려오는 텔레메트리를 그대로 흉내낸 것으로,
# 인증 없이 조회 가능하다 (위성 텔레메트리 수신에는 애초에 OpenC3 로그인이 필요 없음).
# DISABLE_IMAGER_CC에 해당하는 상태 변경은 이 컨트롤러에 없다 — CVE-2025-68271로
# 얻은 임의 코드 실행 안에서 OpenC3::FlameAppModel.disable_imager!를 직접 호출해야 한다.
class FlameAppController < ApplicationController
  before_action { @model_class = OpenC3::FlameAppModel }

  # GET /flame_app/hk?scope=DEFAULT
  def hk
    action do
      render json: @model_class.hk(scope: params[:scope] || 'DEFAULT')
    end
  end

  private

  def action
    yield
  rescue StandardError => e
    render json: { status: 'error', message: e.message }, status: 500
  end
end
