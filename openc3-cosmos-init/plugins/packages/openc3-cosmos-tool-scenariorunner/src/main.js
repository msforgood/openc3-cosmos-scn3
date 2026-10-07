// single-spa bootstrap follows the OpenC3 6.10.1 tool template (LICENSE.txt).
import { createApp, h } from 'vue'
import singleSpaVue from 'single-spa-vue'
import { Dialog, Notify, store, vuetify } from '@openc3/vue-common/plugins'
import App from './App.vue'
import router from './router.js'

const lifecycle = singleSpaVue({
  createApp,
  appOptions: { render: () => h(App), el: '#openc3-tool' },
  handleInstance(app) {
    app.use(router).use(store).use(vuetify).use(Dialog).use(Notify, { store })
  },
})
export const bootstrap = lifecycle.bootstrap
export const mount = lifecycle.mount
export const unmount = lifecycle.unmount
