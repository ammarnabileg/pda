from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from . import api, config, dashboard


def create_app() -> FastAPI:
    app = FastAPI(title="Tamween", docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(SessionMiddleware, secret_key=config.SECRET_KEY, same_site="lax",
                       max_age=12 * 3600, session_cookie="tamween_session")
    app.mount("/static", StaticFiles(directory=str(config.BASE_DIR / "app" / "static")), name="static")
    app.include_router(api.router)
    app.include_router(dashboard.router)

    @app.exception_handler(dashboard.LoginRequired)
    def _login(request: Request, exc):
        return RedirectResponse("/login", status_code=303)

    @app.exception_handler(dashboard.Forbidden)
    def _forbidden(request: Request, exc):
        return HTMLResponse("<p dir=rtl style='font:20px sans-serif;padding:30px'>الصفحة دي للمدير فقط. <a href='/'>الرجوع</a></p>", status_code=403)

    return app


app = create_app()
