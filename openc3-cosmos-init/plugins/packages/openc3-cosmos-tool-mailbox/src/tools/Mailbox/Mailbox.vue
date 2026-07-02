<template>
  <div>
    <top-bar :menus="menus" title="Mailbox" />

    <v-container fluid>
      <v-row>
        <!-- 좌측: 쪽지 목록 -->
        <v-col cols="4">
          <v-card>
            <v-card-title class="d-flex align-center">
              <v-icon class="mr-2">mdi-email-outline</v-icon>
              수신함
              <v-spacer />
              <v-btn icon @click="loadMessages" :loading="loading" size="small">
                <v-icon>mdi-refresh</v-icon>
              </v-btn>
            </v-card-title>
            <v-divider />
            <v-list v-if="messages.length > 0" lines="two">
              <v-list-item
                v-for="msg in messages"
                :key="msg.id"
                :active="selectedId === msg.id"
                active-color="primary"
                @click="selectMessage(msg)"
                class="border-b mailbox-item"
              >
                <v-list-item-title class="font-weight-bold text-truncate">
                  {{ msg.subject }}
                </v-list-item-title>
                <v-list-item-subtitle class="text-truncate">
                  {{ msg.from_email }}
                </v-list-item-subtitle>
                <template v-slot:append>
                  <span class="text-caption text-grey">
                    {{ formatTime(msg.received_at) }}
                  </span>
                </template>
              </v-list-item>
            </v-list>
            <v-card-text v-else class="text-center text-grey">
              수신된 쪽지가 없습니다.
            </v-card-text>
          </v-card>
        </v-col>

        <!-- 우측: 쪽지 내용 -->
        <v-col cols="8">
          <v-card v-if="selected" class="h-100">
            <v-card-title>{{ selected.subject }}</v-card-title>
            <v-card-subtitle>
              <v-icon size="small" class="mr-1">mdi-account</v-icon>
              {{ selected.from_email }}
              <span class="ml-4 text-caption text-grey">
                {{ formatTime(selected.received_at) }}
              </span>
            </v-card-subtitle>
            <v-divider />
            <!-- XSS 취약점: body를 HTML로 그대로 렌더링 (필터 없음) -->
            <v-card-text>
              <div v-html="selected.body" class="message-body"></div>
            </v-card-text>
            <v-card-actions>
              <v-spacer />
              <v-btn color="error" variant="text" @click="deleteMessage(selected.id)">
                <v-icon class="mr-1">mdi-delete</v-icon>
                삭제
              </v-btn>
            </v-card-actions>
          </v-card>
          <v-card v-else class="h-100 d-flex align-center justify-center">
            <v-card-text class="text-center text-grey">
              <v-icon size="64" class="mb-4">mdi-email-open-outline</v-icon>
              <div>쪽지를 선택하면 내용이 표시됩니다.</div>
            </v-card-text>
          </v-card>
        </v-col>
      </v-row>
    </v-container>
  </div>
</template>

<script>
import axios from 'axios'
import { TopBar } from '@openc3/vue-common/components'

export default {
  name: 'Mailbox',
  components: { TopBar },
  data() {
    return {
      messages: [],
      selected: null,
      selectedId: null,
      loading: false,
      menus: [],
    }
  },
  mounted() {
    this.loadMessages()
    // 30초마다 자동 갱신
    this.timer = setInterval(this.loadMessages, 30000)
  },
  beforeUnmount() {
    clearInterval(this.timer)
  },
  methods: {
    async loadMessages() {
      this.loading = true
      try {
        const scope = window.openc3Scope || 'DEFAULT'
        const resp = await axios.get('/openc3-api/mailbox', {
          params: { scope },
        })
        this.messages = resp.data || []
        // 선택된 쪽지가 목록에 여전히 있는지 확인
        if (this.selectedId) {
          const found = this.messages.find((m) => m.id === this.selectedId)
          if (!found) {
            this.selected = null
            this.selectedId = null
          }
        }
      } catch (e) {
        console.error('쪽지 목록 로드 실패:', e)
      } finally {
        this.loading = false
      }
    },
    selectMessage(msg) {
      this.selectedId = msg.id
      this.selected = msg
    },
    async deleteMessage(id) {
      try {
        const scope = window.openc3Scope || 'DEFAULT'
        const token = window.openc3Token || localStorage.getItem('openc3_token') || ''
        await axios.delete(`/openc3-api/mailbox/${id}`, {
          params: { scope },
          headers: { Authorization: token },
        })
        this.selected = null
        this.selectedId = null
        await this.loadMessages()
      } catch (e) {
        console.error('쪽지 삭제 실패:', e)
      }
    },
    formatTime(ts) {
      if (!ts) return ''
      const d = new Date(ts * 1000)
      return d.toLocaleString('ko-KR')
    },
  },
}
</script>

<style scoped>
.message-body {
  min-height: 200px;
  line-height: 1.6;
  font-size: 14px;
}
.border-b {
  border-bottom: 1px solid rgba(0, 0, 0, 0.08);
}
</style>
