module Admin
  # The console's front door. Read-only: it summarises what the namespace holds
  # and points at the screens that change it, so nothing here can mutate a row.
  class ConsoleController < BaseController
    def show
      @summary = User.console_summary
    end
  end
end
