# frozen_string_literal: true
require 'resolv'

class Resolv::DNS::Name

  def +(other)
    raise ArgumentError.new("Can't add to an absolute name!") if self.absolute?
    Resolv::DNS::Name.new(self.to_a + other.to_a, other.absolute?)
  end

  def -(other)
    unless self.absolute? == other.absolute?
      raise ArgumentError.new("Both names must be either relative or absolute")
    end

    unless self.subdomain_of?(other)
      raise ArgumentError.new("Subdomain mismatch")
    end

    a = self.to_a
    Resolv::DNS::Name.new(a.first(a.size - other.to_a.size), false)
  end

end
