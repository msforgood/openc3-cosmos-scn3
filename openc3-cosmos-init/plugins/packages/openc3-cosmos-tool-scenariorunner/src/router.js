import { createRouter, createWebHistory } from 'vue-router'
import { prependBasePath } from '@openc3/js-common/utils'
import ScenarioRunner from './ScenarioRunner.vue'

const routes = [{ path: '/', name: 'ScenarioRunner', component: ScenarioRunner }]
routes.forEach(prependBasePath)
export default createRouter({ history: createWebHistory(), routes })
