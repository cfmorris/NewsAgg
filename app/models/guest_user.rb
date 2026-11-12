# Null object for an anonymous visitor: there is no users row, so it holds no
# capabilities and no identity. Controllers and views ask it the same questions
# they ask a User, so nothing has to branch on nil.
class GuestUser
  def guest?
    true
  end

  def registered?
    false
  end

  def member?
    false
  end

  def admin?
    false
  end

  def super_admin?
    false
  end

  def email
    nil
  end
end
