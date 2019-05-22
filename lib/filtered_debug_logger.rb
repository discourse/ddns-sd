# frozen_string_literal: true
require 'logger'

module FilteredDebugLogger
  def permitted_prognames=(l)
    raise ArgumentError, "Must provide an array" unless l.is_a?(Array)

    @permitted_prognames = l
  end

  def add(s, m = nil, p = nil)
    return if s == Logger::DEBUG && @permitted_prognames && !@permitted_prognames.include?(p)

    super
  end

  alias log add
end

Logger.prepend(FilteredDebugLogger)
