// All authentication logic moved to the API project
// (ControlManagement.Api.Services.AuthService).  The Web tier calls the API
// via AuthApiClient and never holds a database connection.  This file is kept
// empty so the .csproj / solution does not need to be edited; delete it when
// convenient.

namespace ControlManagement.Web.Services;

internal static class ControlLoginService_Removed { }
