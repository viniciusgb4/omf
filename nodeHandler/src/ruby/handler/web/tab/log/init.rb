require 'handler/web/tab/log/logServlet'

include OMF::ExperimentController
Web.registerService Web::Log, 400
