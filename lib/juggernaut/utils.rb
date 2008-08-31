class Hash
  def symbolize_keys!
    keys.each do |key|
      unless key.is_a?(Symbol) || (new_key = key.to_sym).nil?
        self[new_key] = self[key]
        delete(key)
      end
    end
    self
  end
end