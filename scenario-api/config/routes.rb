Rails.application.routes.draw do
  scope '/scenario-api' do
    get '/health', to: 'scenario#health'
    get '/scenarios', to: 'scenario#scenarios'
    get '/scenarios/:id', to: 'scenario#scenario'
    get '/runs', to: 'scenario#runs'
    post '/runs', to: 'scenario#create'
    post '/runs/reconcile', to: 'scenario#reconcile'
    get '/runs/:id', to: 'scenario#show'
    get '/runs/:id/events', to: 'scenario#events'
    get '/runs/:id/context', to: 'scenario#context'
    post '/runs/:id/stop', to: 'scenario#stop'
    post '/runs/:id/prompt', to: 'scenario#prompt'
    post '/runs/:id/callback', to: 'scenario#callback'
  end
end
