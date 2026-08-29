FROM --platform=linux/amd64 ubuntu:latest

# Install nginx and clean up package manager cache
RUN apt-get update && \
    apt-get install -y nginx && \
    rm -rf /var/lib/apt/lists/*

# Copy HTML application to nginx web root
COPY index.html /var/www/html/
COPY README.md /var/www/html/

# Expose port 80
EXPOSE 80

# Start nginx in foreground
CMD ["nginx", "-g", "daemon off;"]
