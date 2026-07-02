# encoding: ascii-8bit

spec = Gem::Specification.new do |s|
  s.name = 'openc3-cosmos-tool-mailbox'
  s.summary = 'OpenC3 COSMOS 쪽지함 Tool'
  s.description = <<-EOF
    이메일 연동 쪽지(내부 메시지) 인터페이스 플러그인
  EOF
  s.authors = ['CTF Challenge']
  s.email   = ['ctf@example.com']
  s.homepage = 'https://github.com/SeoPPak/cFS-Attack-Scenarios'

  s.platform = Gem::Platform::RUBY
  s.required_ruby_version = '>= 3.0'

  if ENV['VERSION']
    s.version = ENV['VERSION'].dup
  else
    time = Time.now.strftime("%Y%m%d%H%M%S")
    s.version = '0.0.0' + ".#{time}"
  end
  s.licenses = ['AGPL-3.0-only']

  s.files = Dir.glob("{targets,lib,tools,microservices}/**/*") + %w(Rakefile LICENSE.txt plugin.txt)
end
