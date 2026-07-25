#!/bin/bash

vagrant ssh -c "kubectl exec -n gitlab deploy/gitlab-toolbox -- gitlab-rails runner \"
u = User.new(username: 'admin', email: 'admin@example.com', name: 'Admin', password: 'admin', password_confirmation: 'admin')
u.skip_confirmation!
u.admin = true
u.save!
\""