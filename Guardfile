# frozen_string_literal: true

guard 'rspec', cmd: "bundle exec rspec", all_on_start: true, all_after_pass: true do
  watch(%r{^spec/.+_spec\.rb$})
  watch(%r{^spec/.+_methods\.rb$}) { 'spec' }
  watch(%r{^spec/fixtures})        { 'spec' }
  watch(%r{^Gemfile})              { 'spec' }
  watch('spec/spec_helper.rb')     { 'spec' }
  watch(%r{^lib/})                 { "spec" }
end

guard :rubocop do
  watch(%r{.+\.rb$})
  watch(%r{(?:.+/)?\.rubocop(?:_todo)?\.yml$}) { |m| File.dirname(m[0]) }
end
