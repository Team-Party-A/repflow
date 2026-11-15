SwaggerUIBundle({
  dom_id: "#swagger-ui",
  url: "/docs/openapi.yaml",
  presets: [SwaggerUIBundle.presets.apis],
  layout: "BaseLayout",
  deepLinking: true,
  supportedSubmitMethods: [],
  validatorUrl: null,
  queryConfigEnabled: false,
  persistAuthorization: false,
});
