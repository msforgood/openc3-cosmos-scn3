// Local browser fixture only. All network APIs are intercepted by smoke.mjs.
import { createApp, h } from 'vue'
import { Dialog, Notify, store, vuetify } from '@openc3/vue-common/plugins'
import '@openc3/vue-common/styles'
import 'vuetify/styles'
import * as components from 'vuetify/components'
import * as directives from 'vuetify/directives'
import ScenarioRunner from '../../src/ScenarioRunner.vue'

window.openc3Scope = 'DEFAULT'
window.OpenC3Auth = { defaultMinValidity: 30, updateToken: async () => false, setTokens() {}, login() { throw new Error('Unexpected real authentication') } }
localStorage.openc3Token = 'browser-fixture-only'
// Production's SystemJS vuetify-labs UMD registers these automatically.
const app = createApp({ render: () => h(components.VApp, {}, () => h(ScenarioRunner)) })
Object.entries(components).forEach(([name, component]) => app.component(name, component))
Object.entries(directives).forEach(([name, directive]) => app.directive(name, directive))
app.use(store).use(vuetify).use(Dialog).use(Notify, { store })
app.mount('#fixture')
window.unmountFixture = () => app.unmount()
