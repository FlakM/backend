use axum::{routing::get, Router};
use std::{net::SocketAddr, path::PathBuf};

use tower_http::{
    services::{ServeDir, ServeFile},
    trace::TraceLayer,
};

use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "example_static_file_server=debug,tower_http=debug".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let parrent = std::env::var("RUNTIME_DIRECTORY").unwrap_or_else(|_| ".".to_string());
    let dir = std::path::Path::new(&parrent).join("assets");

    println!("Serving files from {:?}", dir);
    for dir in std::fs::read_dir(dir.clone()).unwrap() {
        let dir = dir.unwrap();
        let path = dir.path();
        println!("path: {:?}", path);
    }

    // build our application with a route
    let app = using_serve_dir_with_assets_fallback(dir);

    // run it
    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    println!("listening on {}", addr);
    axum::Server::bind(&addr)
        .serve(app.layer(TraceLayer::new_for_http()).into_make_service())
        .await
        .unwrap();
}

fn using_serve_dir_with_assets_fallback(dir: PathBuf) -> Router {
    // `ServeDir` allows setting a fallback if an asset is not found
    // so with this `GET /assets/doesnt-exist.jpg` will return `index.html`
    // rather than a 404
    let serve_dir = ServeDir::new(&dir).not_found_service(ServeFile::new(dir.join("index.html")));

    Router::new()
        .route("/foo", get(|| async { "Hi from /foo" }))
        .nest_service("/assets", serve_dir.clone())
        .fallback_service(serve_dir)
}
