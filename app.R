ui <- page_sidebar(
  title = "Loss Reserving & Risk Analytics Engine",
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  
  sidebar = sidebar(
    h4("Model Parameters"),
    selectInput(
      "method", 
      "Reserving Method:", 
      choices = c("Mack Chain Ladder" = "mack", 
                  "ODP Bootstrap" = "boot")
    ),
    numericInput("simulations", "Bootstrap Iterations:", value = 10000, min = 1000, max = 50000, step = 1000),
    hr(),
  ),
  
  layout_columns(
    fill = FALSE,
    value_box(
      title = "Estimated Ultimate Loss", 
      value = textOutput("tot_ultimate"), 
      showcase = bsicons::bs_icon("cash")
    ),
    value_box(
      title = "Total IBNR Reserve", 
      value = textOutput("tot_ibnr"), 
      showcase = bsicons::bs_icon("bank")
    ),
    value_box(
      title = "95th Percentile VaR (Bootstrap)", 
      value = textOutput("var_95"), 
      showcase = bsicons::bs_icon("shield-exclamation"),
      theme = "danger"
    )
  ),
  
  card(
    card_header("Ultimate Loss by Accident Year"),
    plotlyOutput("projection_plot", height = "400px")
  ),
  
  card(
    card_header("Squared Claims Triangle (Cumulative)"),
    DTOutput("triangle_table")
  )
)

server <- function(input, output, session) {
  
  model_data <- reactive({
    req(cumul_triangle)
    
    if (input$method == "mack") {
      mod <- MackChainLadder(cumul_triangle, est.sigma = "Mack")
      
      cl_summary <- summary(mod)
      ibnr <- sum(cl_summary$ByOrigin$IBNR, na.rm = TRUE)
      ultimate <- sum(cl_summary$ByOrigin$Ultimate, na.rm = TRUE)
      
      list(type = "mack", model = mod, ibnr = ibnr, ultimate = ultimate, var95 = NA)
      
    } else {
      withProgress(message = 'Running Monte Carlo Simulation...', value = 0.5, {
        set.seed(42)
        mod <- BootChainLadder(cumul_triangle, R = input$simulations, process.distr = "od.pois")
      })
      
      ibnr <- mean(mod$IBNR.Totals)
      # Calculate total ultimate across all accident years
      latest_diagonal <- sum(getLatestCumulative(cumul_triangle), na.rm = TRUE)
      ultimate <- latest_diagonal + ibnr 
      var95 <- quantile(mod$IBNR.Totals, 0.95)
      
      list(type = "boot", model = mod, ibnr = ibnr, ultimate = ultimate, var95 = var95)
    }
  })
  
  output$tot_ultimate <- renderText({
    paste0("$", formatC(model_data()$ultimate, format="f", digits=0, big.mark=","))
  })
  
  output$tot_ibnr <- renderText({
    paste0("$", formatC(model_data()$ibnr, format="f", digits=0, big.mark=","))
  })
  
  output$var_95 <- renderText({
    if(is.na(model_data()$var95)) return("N/A")
    paste0("$", formatC(model_data()$var95, format="f", digits=0, big.mark=","))
  })
  
  output$triangle_table <- renderDT({
    if(model_data()$type == "mack") {
      sq_tri <- round(model_data()$model$FullTriangle, 0)
    } else {
      sq_tri <- round(cumul_triangle, 0) 
    }
    
    datatable(as.data.frame(sq_tri), 
              options = list(pageLength = 10, dom = 't', scrollX = TRUE), 
              class = 'cell-border stripe')
  })
  
  output$projection_plot <- renderPlotly({
    req(model_data())
    
    data <- model_data()
    mod <- data$model
    origin_years <- as.numeric(rownames(cumul_triangle))
    
    # Safely extract the latest known paid amounts from the triangle
    latest_paid <- sapply(1:nrow(cumul_triangle), function(i) {
      row_data <- cumul_triangle[i, ]
      tail(na.omit(row_data), 1)
    })
    
    if (data$type == "mack") {
      # Deterministic Plot Geometry
      cl_summary <- summary(mod)
      ibnr <- cl_summary$ByOrigin$IBNR
      
      plot_df <- data.frame(
        Year = origin_years,
        Latest_Paid = latest_paid,
        IBNR = ibnr
      )
      
      plot_ly(plot_df, x = ~Year) %>%
        add_bars(y = ~Latest_Paid, name = 'Latest Paid', marker = list(color = '#2c3e50')) %>%
        add_bars(y = ~IBNR, name = 'Deterministic IBNR', marker = list(color = '#18bc9c')) %>%
        layout(barmode = 'stack',
               title = "Deterministic Ultimate Loss Projection",
               yaxis = list(title = "Estimated Ultimate Loss ($)"),
               xaxis = list(title = "Accident Year", tickmode = 'linear'),
               hovermode = "x unified")
      
    } else {
      # Stochastic Plot Geometry (with Risk Buffers)
      # Extract the matrix of simulations by origin year
      sim_ibnr <- mod$IBNR.ByOrigin
      
      # Calculate metrics and wrap them in as.numeric() to strip hidden metadata
      mean_ibnr <- as.numeric(colMeans(sim_ibnr))
      p75_ibnr <- as.numeric(apply(sim_ibnr, 2, quantile, probs = 0.75))
      p95_ibnr <- as.numeric(apply(sim_ibnr, 2, quantile, probs = 0.95))
      
      clean_latest_paid <- as.numeric(latest_paid)
      clean_years <- as.numeric(origin_years)
      
      plot_df <- data.frame(
        Year = clean_years,
        Latest_Paid = clean_latest_paid,
        Mean_IBNR = mean_ibnr,
        Buffer_75 = p75_ibnr - mean_ibnr, 
        Buffer_95 = p95_ibnr - p75_ibnr   
      )
      
      plot_ly(plot_df, x = ~Year) %>%
        add_bars(y = ~Latest_Paid, name = 'Latest Paid', marker = list(color = '#2c3e50')) %>%
        add_bars(y = ~Mean_IBNR, name = 'Mean Expected IBNR', marker = list(color = '#3498db')) %>%
        add_bars(y = ~Buffer_75, name = '75th Percentile VaR', marker = list(color = '#f39c12')) %>%
        add_bars(y = ~Buffer_95, name = '95th Percentile VaR', marker = list(color = '#e74c3c')) %>%
        layout(barmode = 'stack',
               title = "Stochastic Ultimate Loss Projection with Risk Buffers",
               yaxis = list(title = "Estimated Ultimate Loss ($)"),
               xaxis = list(title = "Accident Year", tickmode = 'linear'),
               hovermode = "x unified")
    }
  })
}

shinyApp(ui, server)
