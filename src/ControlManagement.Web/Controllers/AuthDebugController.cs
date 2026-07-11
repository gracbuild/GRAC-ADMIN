// AuthDebugController removed.  The Web tier no longer holds a database
// connection, so the diagnostic endpoints that probed cm_user directly are
// obsolete.  If similar diagnostics are needed in the future, add them to the
// API project (where they belong) gated by IWebHostEnvironment.IsDevelopment().
