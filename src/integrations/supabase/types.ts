export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.15"
  }
  public: {
    Tables: {
      accounting_periods: {
        Row: {
          closed_at: string | null
          closed_by: string | null
          created_at: string
          id: string
          opened_at: string
          period_month: number
          period_year: number
          status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          id?: string
          opened_at?: string
          period_month: number
          period_year: number
          status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          id?: string
          opened_at?: string
          period_month?: number
          period_year?: number
          status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      account_transactions: {
        Row: {
          amount: number
          counter_customer_id: string | null
          created_at: string
          customer_id: string
          deleted_at: string | null
          deleted_by: string | null
          description: string
          document_no: string
          due_date: string | null
          id: string
          journal_entry_id: string | null
          source: string
          source_id: string | null
          txn_date: string
          txn_type: string
          updated_at: string
          user_id: string
        }
        Insert: {
          amount?: number
          counter_customer_id?: string | null
          created_at?: string
          customer_id: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          due_date?: string | null
          id?: string
          journal_entry_id?: string | null
          source?: string
          source_id?: string | null
          txn_date?: string
          txn_type?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          amount?: number
          counter_customer_id?: string | null
          created_at?: string
          customer_id?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          due_date?: string | null
          id?: string
          journal_entry_id?: string | null
          source?: string
          source_id?: string | null
          txn_date?: string
          txn_type?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_transactions_counter_customer_id_fkey"
            columns: ["counter_customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "account_transactions_counter_customer_id_fkey"
            columns: ["counter_customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "account_transactions_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "account_transactions_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "account_transactions_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      admin_audit_log: {
        Row: {
          action: string
          admin_user_id: string
          created_at: string
          details: Json
          id: string
          target_user_id: string | null
        }
        Insert: {
          action: string
          admin_user_id: string
          created_at?: string
          details?: Json
          id?: string
          target_user_id?: string | null
        }
        Update: {
          action?: string
          admin_user_id?: string
          created_at?: string
          details?: Json
          id?: string
          target_user_id?: string | null
        }
        Relationships: []
      }
      audit_logs: {
        Row: {
          action: string
          created_at: string
          id: string
          metadata: Json | null
          new_data: Json | null
          old_data: Json | null
          record_id: string
          table_name: string
          user_id: string
        }
        Insert: {
          action: string
          created_at?: string
          id?: string
          metadata?: Json | null
          new_data?: Json | null
          old_data?: Json | null
          record_id: string
          table_name: string
          user_id: string
        }
        Update: {
          action?: string
          created_at?: string
          id?: string
          metadata?: Json | null
          new_data?: Json | null
          old_data?: Json | null
          record_id?: string
          table_name?: string
          user_id?: string
        }
        Relationships: []
      }
      chart_of_accounts: {
        Row: {
          account_type: string
          code: string
          created_at: string
          id: string
          is_active: boolean
          is_system: boolean
          level: number
          name: string
          normal_balance: string
          parent_id: string | null
          system_tag: string | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          account_type: string
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          is_system?: boolean
          level?: number
          name: string
          normal_balance: string
          parent_id?: string | null
          system_tag?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          account_type?: string
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          is_system?: boolean
          level?: number
          name?: string
          normal_balance?: string
          parent_id?: string | null
          system_tag?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "chart_of_accounts_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "chart_of_accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      currencies: {
        Row: {
          code: string
          created_at: string
          decimal_places: number
          is_active: boolean
          name: string
          symbol: string
        }
        Insert: {
          code: string
          created_at?: string
          decimal_places?: number
          is_active?: boolean
          name: string
          symbol: string
        }
        Update: {
          code?: string
          created_at?: string
          decimal_places?: number
          is_active?: boolean
          name?: string
          symbol?: string
        }
        Relationships: []
      }
      entry_counters: {
        Row: {
          counter_type: string
          last_number: number
          updated_at: string
          user_id: string
          year: number
        }
        Insert: {
          counter_type?: string
          last_number?: number
          updated_at?: string
          user_id: string
          year: number
        }
        Update: {
          counter_type?: string
          last_number?: number
          updated_at?: string
          user_id?: string
          year?: number
        }
        Relationships: []
      }
      exchange_rates: {
        Row: {
          buying_rate: number
          created_at: string
          currency_code: string
          id: string
          rate_date: string
          rate_type: string
          selling_rate: number
          user_id: string | null
        }
        Insert: {
          buying_rate: number
          created_at?: string
          currency_code: string
          id?: string
          rate_date: string
          rate_type?: string
          selling_rate: number
          user_id?: string | null
        }
        Update: {
          buying_rate?: number
          created_at?: string
          currency_code?: string
          id?: string
          rate_date?: string
          rate_type?: string
          selling_rate?: number
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "exchange_rates_currency_code_fkey"
            columns: ["currency_code"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      customers: {
        Row: {
          address: string
          city: string
          code: string
          contact_name: string
          created_at: string
          deleted_at: string | null
          deleted_by: string | null
          district: string
          email: string
          id: string
          neighborhood: string
          note: string
          opening_balance: number
          partner_group: string
          partner_type: string
          payment_term_days: number
          phone: string
          risk_limit: number
          tax_office: string
          title: string
          updated_at: string
          user_id: string
          vkn_tckn: string
        }
        Insert: {
          address?: string
          city?: string
          code?: string
          contact_name?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          district?: string
          email?: string
          id?: string
          neighborhood?: string
          note?: string
          opening_balance?: number
          partner_group?: string
          partner_type?: string
          payment_term_days?: number
          phone?: string
          risk_limit?: number
          tax_office?: string
          title: string
          updated_at?: string
          user_id: string
          vkn_tckn: string
        }
        Update: {
          address?: string
          city?: string
          code?: string
          contact_name?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          district?: string
          email?: string
          id?: string
          neighborhood?: string
          note?: string
          opening_balance?: number
          partner_group?: string
          partner_type?: string
          payment_term_days?: number
          phone?: string
          risk_limit?: number
          tax_office?: string
          title?: string
          updated_at?: string
          user_id?: string
          vkn_tckn?: string
        }
        Relationships: []
      }
      efatura_connection_settings: {
        Row: {
          active_provider: string
          created_at: string
          gib_enabled: boolean
          gib_environment: string
          gib_last_error: string
          gib_last_tested_at: string | null
          gib_password_encrypted: string | null
          gib_status: string
          gib_username: string
          integrator_api_key_encrypted: string | null
          integrator_api_username: string
          integrator_base_url: string
          integrator_enabled: boolean
          integrator_last_error: string
          integrator_last_tested_at: string | null
          integrator_provider: string
          integrator_status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          active_provider?: string
          created_at?: string
          gib_enabled?: boolean
          gib_environment?: string
          gib_last_error?: string
          gib_last_tested_at?: string | null
          gib_password_encrypted?: string | null
          gib_status?: string
          gib_username?: string
          integrator_api_key_encrypted?: string | null
          integrator_api_username?: string
          integrator_base_url?: string
          integrator_enabled?: boolean
          integrator_last_error?: string
          integrator_last_tested_at?: string | null
          integrator_provider?: string
          integrator_status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          active_provider?: string
          created_at?: string
          gib_enabled?: boolean
          gib_environment?: string
          gib_last_error?: string
          gib_last_tested_at?: string | null
          gib_password_encrypted?: string | null
          gib_status?: string
          gib_username?: string
          integrator_api_key_encrypted?: string | null
          integrator_api_username?: string
          integrator_base_url?: string
          integrator_enabled?: boolean
          integrator_last_error?: string
          integrator_last_tested_at?: string | null
          integrator_provider?: string
          integrator_status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      invoices: {
        Row: {
          cancel_date: string | null
          created_at: string
          currency: string
          customer: Json
          customer_id: string | null
          deleted_at: string | null
          deleted_by: string | null
          ettn: string
          exchange_rate: number
          gib_approval_date: string | null
          grand_total: number
          id: string
          invoice_date: string
          invoice_number: string
          items: Json
          notes: string
          payment_info: string
          posted: boolean
          status: string
          subtotal: number
          taxable_amount: number
          total_discount: number
          total_tevkifat: number
          total_vat: number
          type: string
          updated_at: string
          user_id: string
          warehouse_id: string | null
        }
        Insert: {
          cancel_date?: string | null
          created_at?: string
          currency?: string
          customer?: Json
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          ettn: string
          exchange_rate?: number
          gib_approval_date?: string | null
          grand_total?: number
          id?: string
          invoice_date?: string
          invoice_number: string
          items?: Json
          notes?: string
          payment_info?: string
          posted?: boolean
          status?: string
          subtotal?: number
          taxable_amount?: number
          total_discount?: number
          total_tevkifat?: number
          total_vat?: number
          type?: string
          updated_at?: string
          user_id: string
          warehouse_id?: string | null
        }
        Update: {
          cancel_date?: string | null
          created_at?: string
          currency?: string
          customer?: Json
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          ettn?: string
          exchange_rate?: number
          gib_approval_date?: string | null
          grand_total?: number
          id?: string
          invoice_date?: string
          invoice_number?: string
          items?: Json
          notes?: string
          payment_info?: string
          posted?: boolean
          status?: string
          subtotal?: number
          taxable_amount?: number
          total_discount?: number
          total_tevkifat?: number
          total_vat?: number
          type?: string
          updated_at?: string
          user_id?: string
          warehouse_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_warehouse_id_fkey"
            columns: ["warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_items: {
        Row: {
          created_at: string
          currency: string
          description: string
          discount_rate: number
          exchange_rate: number
          foreign_amount: number | null
          id: string
          invoice_id: string
          line_number: number
          line_total: number
          product_id: string | null
          quantity: number
          taxable_amount: number
          unit: string
          unit_price: number
          user_id: string
          vat_amount: number
          vat_rate: number
        }
        Insert: {
          created_at?: string
          currency?: string
          description?: string
          discount_rate?: number
          exchange_rate?: number
          foreign_amount?: number | null
          id?: string
          invoice_id: string
          line_number: number
          line_total: number
          product_id?: string | null
          quantity: number
          taxable_amount: number
          unit?: string
          unit_price: number
          user_id: string
          vat_amount?: number
          vat_rate?: number
        }
        Update: {
          created_at?: string
          currency?: string
          description?: string
          discount_rate?: number
          exchange_rate?: number
          foreign_amount?: number | null
          id?: string
          invoice_id?: string
          line_number?: number
          line_total?: number
          product_id?: string | null
          quantity?: number
          taxable_amount?: number
          unit?: string
          unit_price?: number
          user_id?: string
          vat_amount?: number
          vat_rate?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoice_items_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_tax_lines: {
        Row: {
          created_at: string
          currency: string
          direction: string
          exchange_rate: number
          exemption_code: string | null
          id: string
          invoice_id: string
          is_cancelled: boolean
          is_exempt: boolean
          is_reversal: boolean
          period_month: number
          period_year: number
          reversal_of: string | null
          tax_amount: number
          tax_amount_try: number
          taxable_amount: number
          taxable_amount_try: number
          user_id: string
          vat_rate: number
          withholding_amount: number
          withholding_rate: number
        }
        Insert: {
          created_at?: string
          currency?: string
          direction: string
          exchange_rate?: number
          exemption_code?: string | null
          id?: string
          invoice_id: string
          is_cancelled?: boolean
          is_exempt?: boolean
          is_reversal?: boolean
          period_month: number
          period_year: number
          reversal_of?: string | null
          tax_amount: number
          tax_amount_try: number
          taxable_amount: number
          taxable_amount_try: number
          user_id: string
          vat_rate: number
          withholding_amount?: number
          withholding_rate?: number
        }
        Update: {
          created_at?: string
          currency?: string
          direction?: string
          exchange_rate?: number
          exemption_code?: string | null
          id?: string
          invoice_id?: string
          is_cancelled?: boolean
          is_exempt?: boolean
          is_reversal?: boolean
          period_month?: number
          period_year?: number
          reversal_of?: string | null
          tax_amount?: number
          tax_amount_try?: number
          taxable_amount?: number
          taxable_amount_try?: number
          user_id?: string
          vat_rate?: number
          withholding_amount?: number
          withholding_rate?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoice_tax_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_tax_lines_reversal_of_fkey"
            columns: ["reversal_of"]
            isOneToOne: false
            referencedRelation: "invoice_tax_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      journal_entries: {
        Row: {
          created_at: string
          description: string | null
          entry_date: string
          entry_number: string
          entry_type: string
          id: string
          period_month: number
          period_year: number
          source_id: string | null
          source_type: string | null
          status: string
          total_credit: number
          total_debit: number
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          entry_date?: string
          entry_number: string
          entry_type: string
          id?: string
          period_month: number
          period_year: number
          source_id?: string | null
          source_type?: string | null
          status?: string
          total_credit?: number
          total_debit?: number
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          description?: string | null
          entry_date?: string
          entry_number?: string
          entry_type?: string
          id?: string
          period_month?: number
          period_year?: number
          source_id?: string | null
          source_type?: string | null
          status?: string
          total_credit?: number
          total_debit?: number
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      journal_lines: {
        Row: {
          account_id: string
          created_at: string
          credit: number
          currency: string
          debit: number
          description: string | null
          exchange_rate: number
          foreign_amount: number | null
          id: string
          journal_entry_id: string
          user_id: string
        }
        Insert: {
          account_id: string
          created_at?: string
          credit?: number
          currency?: string
          debit?: number
          description?: string | null
          exchange_rate?: number
          foreign_amount?: number | null
          id?: string
          journal_entry_id: string
          user_id: string
        }
        Update: {
          account_id?: string
          created_at?: string
          credit?: number
          currency?: string
          debit?: number
          description?: string | null
          exchange_rate?: number
          foreign_amount?: number | null
          id?: string
          journal_entry_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "journal_lines_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "chart_of_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "journal_lines_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      legal_documents: {
        Row: {
          content: string
          created_at: string
          created_by: string | null
          doc_type: string
          id: string
          is_published: boolean
          published_at: string
          requires_reacceptance: boolean
          title: string
          updated_at: string
          version: string
        }
        Insert: {
          content: string
          created_at?: string
          created_by?: string | null
          doc_type: string
          id?: string
          is_published?: boolean
          published_at?: string
          requires_reacceptance?: boolean
          title: string
          updated_at?: string
          version: string
        }
        Update: {
          content?: string
          created_at?: string
          created_by?: string | null
          doc_type?: string
          id?: string
          is_published?: boolean
          published_at?: string
          requires_reacceptance?: boolean
          title?: string
          updated_at?: string
          version?: string
        }
        Relationships: []
      }
      payment_allocations: {
        Row: {
          allocated_amount: number
          allocated_date: string
          created_at: string
          id: string
          invoice_id: string
          payment_id: string
          user_id: string
        }
        Insert: {
          allocated_amount: number
          allocated_date?: string
          created_at?: string
          id?: string
          invoice_id: string
          payment_id: string
          user_id: string
        }
        Update: {
          allocated_amount?: number
          allocated_date?: string
          created_at?: string
          id?: string
          invoice_id?: string
          payment_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
        ]
      }
      payments: {
        Row: {
          amount: number
          amount_try: number
          created_at: string
          currency: string
          customer_id: string | null
          deleted_at: string | null
          deleted_by: string | null
          description: string | null
          direction: string
          exchange_rate: number
          id: string
          journal_entry_id: string | null
          payment_date: string
          payment_method: string
          updated_at: string
          user_id: string
        }
        Insert: {
          amount: number
          amount_try: number
          created_at?: string
          currency?: string
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string | null
          direction: string
          exchange_rate?: number
          id?: string
          journal_entry_id?: string | null
          payment_date?: string
          payment_method?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          amount?: number
          amount_try?: number
          created_at?: string
          currency?: string
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string | null
          direction?: string
          exchange_rate?: number
          id?: string
          journal_entry_id?: string | null
          payment_date?: string
          payment_method?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "payments_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      pos_sales: {
        Row: {
          created_at: string
          deleted_at: string | null
          deleted_by: string | null
          description: string
          document_no: string
          gross_amount: number
          id: string
          net_amount: number
          payment_type: string
          sale_date: string
          updated_at: string
          user_id: string
          vat_amount: number
          vat_rate: number
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          gross_amount?: number
          id?: string
          net_amount?: number
          payment_type?: string
          sale_date?: string
          updated_at?: string
          user_id: string
          vat_amount?: number
          vat_rate?: number
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          gross_amount?: number
          id?: string
          net_amount?: number
          payment_type?: string
          sale_date?: string
          updated_at?: string
          user_id?: string
          vat_amount?: number
          vat_rate?: number
        }
        Relationships: []
      }
      products: {
        Row: {
          barcode: string
          category: string
          code: string
          created_at: string
          deleted_at: string | null
          deleted_by: string | null
          description: string
          discount_rate: number
          id: string
          min_stock: number
          name: string
          purchase_price: number
          track_stock: boolean
          unit: string
          unit_price: number
          updated_at: string
          user_id: string
          vat_rate: number
        }
        Insert: {
          barcode?: string
          category?: string
          code?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          discount_rate?: number
          id?: string
          min_stock?: number
          name: string
          purchase_price?: number
          track_stock?: boolean
          unit?: string
          unit_price?: number
          updated_at?: string
          user_id: string
          vat_rate?: number
        }
        Update: {
          barcode?: string
          category?: string
          code?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          discount_rate?: number
          id?: string
          min_stock?: number
          name?: string
          purchase_price?: number
          track_stock?: boolean
          unit?: string
          unit_price?: number
          updated_at?: string
          user_id?: string
          vat_rate?: number
        }
        Relationships: []
      }
      profiles: {
        Row: {
          address: string
          company_title: string
          created_at: string
          email: string
          id: string
          phone: string
          tax_office: string
          updated_at: string
          vkn_tckn: string
        }
        Insert: {
          address?: string
          company_title?: string
          created_at?: string
          email?: string
          id: string
          phone?: string
          tax_office?: string
          updated_at?: string
          vkn_tckn?: string
        }
        Update: {
          address?: string
          company_title?: string
          created_at?: string
          email?: string
          id?: string
          phone?: string
          tax_office?: string
          updated_at?: string
          vkn_tckn?: string
        }
        Relationships: []
      }
      stock_movements: {
        Row: {
          created_at: string
          customer_id: string | null
          deleted_at: string | null
          deleted_by: string | null
          description: string
          document_no: string
          id: string
          movement_date: string
          movement_type: string
          product_id: string
          quantity: number
          source: string
          source_id: string | null
          target_warehouse_id: string | null
          total_cost: number | null
          transfer_group_id: string | null
          unit_cost: number | null
          unit_price: number
          updated_at: string
          user_id: string
          warehouse_id: string | null
        }
        Insert: {
          created_at?: string
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          id?: string
          movement_date?: string
          movement_type?: string
          product_id: string
          quantity?: number
          source?: string
          source_id?: string | null
          target_warehouse_id?: string | null
          total_cost?: number | null
          transfer_group_id?: string | null
          unit_cost?: number | null
          unit_price?: number
          updated_at?: string
          user_id: string
          warehouse_id?: string | null
        }
        Update: {
          created_at?: string
          customer_id?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          description?: string
          document_no?: string
          id?: string
          movement_date?: string
          movement_type?: string
          product_id?: string
          quantity?: number
          source?: string
          source_id?: string | null
          target_warehouse_id?: string | null
          total_cost?: number | null
          transfer_group_id?: string | null
          unit_cost?: number | null
          unit_price?: number
          updated_at?: string
          user_id?: string
          warehouse_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "stock_movements_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "stock_movements_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "product_stocks"
            referencedColumns: ["product_id"]
          },
          {
            foreignKeyName: "stock_movements_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_target_warehouse_id_fkey"
            columns: ["target_warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_warehouse_id_fkey"
            columns: ["warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
        ]
      }
      subscription_reminders: {
        Row: {
          email: string
          end_date: string
          id: string
          sent_at: string
          threshold_days: number
          user_id: string
        }
        Insert: {
          email: string
          end_date: string
          id?: string
          sent_at?: string
          threshold_days: number
          user_id: string
        }
        Update: {
          email?: string
          end_date?: string
          id?: string
          sent_at?: string
          threshold_days?: number
          user_id?: string
        }
        Relationships: []
      }
      subscriptions: {
        Row: {
          created_at: string
          end_date: string
          id: string
          last_payment_date: string | null
          plan: string
          renewal_price: number | null
          start_date: string
          status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          end_date?: string
          id?: string
          last_payment_date?: string | null
          plan?: string
          renewal_price?: number | null
          start_date?: string
          status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          end_date?: string
          id?: string
          last_payment_date?: string | null
          plan?: string
          renewal_price?: number | null
          start_date?: string
          status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      user_consents: {
        Row: {
          accepted: boolean
          accepted_at: string
          consent_type: string
          created_at: string
          document_version: string
          id: string
          user_agent: string
          user_id: string
        }
        Insert: {
          accepted?: boolean
          accepted_at?: string
          consent_type: string
          created_at?: string
          document_version?: string
          id?: string
          user_agent?: string
          user_id: string
        }
        Update: {
          accepted?: boolean
          accepted_at?: string
          consent_type?: string
          created_at?: string
          document_version?: string
          id?: string
          user_agent?: string
          user_id?: string
        }
        Relationships: []
      }
      user_roles: {
        Row: {
          created_at: string
          id: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: []
      }
      warehouses: {
        Row: {
          address: string
          created_at: string
          deleted_at: string | null
          deleted_by: string | null
          id: string
          is_default: boolean
          name: string
          updated_at: string
          user_id: string
        }
        Insert: {
          address?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          is_default?: boolean
          name: string
          updated_at?: string
          user_id: string
        }
        Update: {
          address?: string
          created_at?: string
          deleted_at?: string | null
          deleted_by?: string | null
          id?: string
          is_default?: boolean
          name?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      customer_balances: {
        Row: {
          balance: number | null
          customer_id: string | null
          total_credit: number | null
          total_debit: number | null
          user_id: string | null
        }
        Relationships: []
      }
      product_stocks: {
        Row: {
          product_id: string | null
          quantity: number | null
          user_id: string | null
        }
        Relationships: []
      }
      v_account_balances: {
        Row: {
          account_code: string | null
          account_id: string | null
          account_name: string | null
          account_type: string | null
          credit_balance: number | null
          debit_balance: number | null
          is_system: boolean | null
          net_balance: number | null
          normal_balance: string | null
          total_credit: number | null
          total_debit: number | null
          user_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      assert_accounting_period_open: {
        Args: {
          p_date: string
          p_user_id: string
        }
        Returns: undefined
      }
      get_account_ledger: {
        Args: {
          p_account_id: string
          p_end_date?: string | null
          p_start_date?: string | null
        }
        Returns: {
          credit: number
          debit: number
          description: string
          entry_date: string
          entry_number: string
          journal_entry_id: string
          journal_line_id: string
          running_balance: number
          source_id: string | null
          source_type: string
        }[]
      }
      get_income_statement: {
        Args: {
          p_end_date?: string | null
          p_start_date?: string | null
        }
        Returns: Json
      }
      get_reconciliation_summary: {
        Args: {
          p_month?: number | null
          p_year?: number | null
        }
        Returns: Json
      }
      get_trial_balance: {
        Args: {
          p_end_date?: string | null
          p_start_date?: string | null
        }
        Returns: {
          account_code: string
          account_id: string
          account_name: string
          account_type: string
          closing_credit: number
          closing_debit: number
          credit_balance: number
          debit_balance: number
          is_system: boolean
          net_balance: number
          normal_balance: string
          opening_credit: number
          opening_debit: number
          period_credit: number
          period_debit: number
        }[]
      }
      run_accounting_audit: {
        Args: {
          p_month?: number | null
          p_year?: number | null
        }
        Returns: {
          actual_value: number
          check_name: string
          detail: string
          difference: number
          expected_value: number
          severity: string
          source_id: string | null
          status: string
        }[]
      }
      cancel_purchase_invoice: {
        Args: {
          p_cancel_reason?: string
          p_invoice_id: string
        }
        Returns: Json
      }
      cancel_sales_invoice: {
        Args: {
          p_cancel_reason?: string
          p_invoice_id: string
        }
        Returns: Json
      }
      close_accounting_period: {
        Args: {
          p_month: number
          p_year: number
        }
        Returns: Json
      }
      create_purchase_invoice: {
        Args: {
          p_currency?: string
          p_ettn?: string | null
          p_exchange_rate?: number
          p_grand_total?: number
          p_invoice_date: string
          p_invoice_number: string
          p_items?: Json
          p_notes?: string
          p_payment_info?: string
          p_status?: string
          p_subtotal?: number
          p_supplier_id: string
          p_supplier_info?: Json
          p_taxable_amount?: number
          p_total_discount?: number
          p_total_tevkifat?: number
          p_total_vat?: number
          p_warehouse_id?: string | null
        }
        Returns: Json
      }
      create_purchase_return: {
        Args: {
          p_items: Json
          p_notes?: string
          p_original_invoice_id: string
          p_return_date: string
          p_return_invoice_number: string
          p_warehouse_id?: string | null
        }
        Returns: Json
      }
      create_supplier_payment: {
        Args: {
          p_amount: number
          p_description?: string
          p_document_no?: string
          p_payment_date: string
          p_payment_method?: string
          p_supplier_id: string
        }
        Returns: Json
      }
      get_foreign_currency_balances: {
        Args: Record<PropertyKey, never>
        Returns: Json
      }
      run_fx_revaluation: {
        Args: {
          p_description?: string
          p_rates: Json
          p_revaluation_date: string
        }
        Returns: Json
      }
      get_vat_declaration_summary: {
        Args: {
          p_month?: number | null
          p_year?: number | null
        }
        Returns: Json
      }
      get_withholding_tax_summary: {
        Args: {
          p_month?: number | null
          p_year?: number | null
        }
        Returns: Json
      }
      reopen_accounting_period: {
        Args: {
          p_month: number
          p_year: number
        }
        Returns: Json
      }
      create_sales_invoice: {
        Args: {
          p_currency?: string
          p_customer_id?: string | null
          p_customer_info?: Json
          p_ettn?: string | null
          p_exchange_rate?: number
          p_grand_total?: number
          p_invoice_date: string
          p_invoice_number?: string | null
          p_items?: Json
          p_notes?: string
          p_payment_info?: string
          p_status?: string
          p_subtotal?: number
          p_taxable_amount?: number
          p_total_discount?: number
          p_total_tevkifat?: number
          p_total_vat?: number
          p_type?: string
          p_warehouse_id?: string | null
        }
        Returns: Json
      }
      get_product_moving_average_cost: {
        Args: {
          p_product_id: string
          p_warehouse_id?: string | null
        }
        Returns: number
      }
      get_product_stock_quantity: {
        Args: {
          p_product_id: string
          p_warehouse_id?: string | null
        }
        Returns: number
      }
      has_active_subscription: { Args: { _user_id: string }; Returns: boolean }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      next_entry_number: {
        Args: {
          p_type?: string
          p_user_id: string
          p_year: number
        }
        Returns: string
      }
    }
    Enums: {
      app_role: "admin" | "user"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_role: ["admin", "user"],
    },
  },
} as const
