# Operator tooling for accounts when nobody can sign in yet, or when the role
# matrix has to be repaired from a console.
namespace :users do
  desc "Set a user's role: users:promote[email,role] (member|admin|super_admin)"
  task :promote, [:email, :role] => :environment do |_task, args|
    role = args[:role].to_s.strip
    email = args[:email].to_s.strip

    unless User::ROLES.include?(role)
      abort "Unknown role #{role.inspect}. Use one of: #{User::ROLES.join(", ")}."
    end

    user = User.find_by(email: email.downcase)
    abort "No account with email #{email.inspect}." unless user

    user.update!(role: role)
    puts "#{user.email} is now #{user.role.tr("_", " ")}."
  end

  desc "List every account with its role and state"
  task :list => :environment do
    users = User.order(:id)
    if users.empty?
      puts "No accounts yet."
      next
    end

    users.each do |user|
      state = user.disabled? ? "disabled" : "active"
      puts format("%-32s %-12s %s", user.email, user.role.tr("_", " "), state)
    end
  end
end
